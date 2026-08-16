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
    case root
}

public extension SortColumn {
    static let optimizedIndexColumns: [SortColumn] = [
        .name,
        .path,
        .modified,
        .created,
        .size,
        .fileExtension,
        .kind,
        .volume,
        .root
    ]
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
    public let mode: SearchMode

    public init(
        query: String,
        sort: SortSpec,
        includeHidden: Bool = true,
        mode: SearchMode = .complete
    ) {
        self.query = query
        self.sort = sort
        self.includeHidden = includeHidden
        self.mode = mode
    }
}

public enum SearchMode: Sendable {
    case complete
    case interactivePreview
}

public enum SearchCompleteness: Equatable, Sendable {
    case partial
    case complete
}

extension SearchMode {
    var metricPhase: SearchMetricPhase {
        switch self {
        case .interactivePreview:
            return .initialResults
        case .complete:
            return .refinedResults
        }
    }
}

public enum MatchClass: Int, Codable, CaseIterable, Sendable {
    case metadata = 0
    case weakPath = 1
    case near = 2
    case substring = 3
    case prefix = 4
    case exact = 5
    case alias = 6
}

public struct MatchQuality: Codable, Equatable, Comparable, Sendable {
    public let matchClass: MatchClass
    public let scoreBin: Int

    var sortRank: Int {
        // Raw values are persisted and used by settings UI tags; ranking is independent.
        switch matchClass {
        case .metadata:
            return 0
        case .weakPath:
            return 1
        case .near:
            return 2
        case .substring:
            return 3
        case .alias:
            return 4
        case .prefix:
            return 5
        case .exact:
            return 6
        }
    }

    public init(matchClass: MatchClass, scoreBin: Int) {
        self.matchClass = matchClass
        self.scoreBin = max(0, min(scoreBin, 4))
    }

    public init(matchClass: MatchClass, score: Int) {
        self.init(matchClass: matchClass, scoreBin: score / 2_000)
    }

    public static func < (lhs: MatchQuality, rhs: MatchQuality) -> Bool {
        if lhs.sortRank != rhs.sortRank {
            return lhs.sortRank < rhs.sortRank
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
    public let isAliasDerived: Bool

    public var matchClass: MatchClass {
        quality.matchClass
    }

    private enum CodingKeys: String, CodingKey {
        case quality
        case score
        case field
        case reason
        case spans
        case isAliasDerived
    }

    public init(
        matchClass: MatchClass,
        score: Int,
        field: MatchField,
        reason: String,
        spans: [MatchSpan] = [],
        isAliasDerived: Bool = false
    ) {
        self.quality = MatchQuality(matchClass: matchClass, score: score)
        self.score = score
        self.field = field
        self.reason = reason
        self.spans = spans
        self.isAliasDerived = isAliasDerived
    }

    public init(
        quality: MatchQuality,
        score: Int,
        field: MatchField,
        reason: String,
        spans: [MatchSpan] = [],
        isAliasDerived: Bool = false
    ) {
        self.quality = quality
        self.score = score
        self.field = field
        self.reason = reason
        self.spans = spans
        self.isAliasDerived = isAliasDerived
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quality = try container.decode(MatchQuality.self, forKey: .quality)
        score = try container.decode(Int.self, forKey: .score)
        field = try container.decode(MatchField.self, forKey: .field)
        reason = try container.decode(String.self, forKey: .reason)
        spans = try container.decode([MatchSpan].self, forKey: .spans)
        isAliasDerived = try container.decodeIfPresent(Bool.self, forKey: .isAliasDerived) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(quality, forKey: .quality)
        try container.encode(score, forKey: .score)
        try container.encode(field, forKey: .field)
        try container.encode(reason, forKey: .reason)
        try container.encode(spans, forKey: .spans)
        try container.encode(isAliasDerived, forKey: .isAliasDerived)
    }
}

public struct SearchResult: Identifiable, Sendable {
    public let record: FileRecord
    public let score: Int
    public let match: MatchExplanation?
    public let rootPath: String?

    public init(record: FileRecord, score: Int, match: MatchExplanation? = nil, rootPath: String? = nil) {
        self.record = record
        self.score = score
        self.match = match
        self.rootPath = rootPath
    }

    public var id: UInt64 {
        record.id
    }
}

extension SearchResult: SearchRecordReadable {
    var path: String { record.path }
    var name: String { record.name }
    var directoryPath: String { record.directoryPath }
    var fileExtension: String { record.fileExtension }
    var sizeBytes: UInt64 { record.sizeBytes }
    var modifiedTime: TimeInterval { record.modifiedTime }
    var createdTime: TimeInterval? { record.createdTime }
    var isDirectory: Bool { record.isDirectory }
    var isHidden: Bool { record.isHidden }
    var volumeName: String { record.volumeName }
    var normalizedName: String { record.normalizedName }
    var normalizedPath: String { record.normalizedPath }
}

public struct SearchResponse: Sendable {
    public let results: [SearchResult]
    public let totalMatches: Int
    public let elapsed: TimeInterval
    public let snapshotRevision: UInt64?
    public let usesIndexedCandidates: Bool
    public let completeness: SearchCompleteness
    public let executionProfile: SearchExecutionProfile

    public init(
        results: [SearchResult],
        totalMatches: Int,
        elapsed: TimeInterval,
        snapshotRevision: UInt64? = nil,
        usesIndexedCandidates: Bool = false,
        completeness: SearchCompleteness = .complete,
        executionProfile: SearchExecutionProfile? = nil
    ) {
        self.results = results
        self.totalMatches = totalMatches
        self.elapsed = elapsed
        self.snapshotRevision = snapshotRevision
        self.usesIndexedCandidates = usesIndexedCandidates
        self.completeness = completeness
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

public enum RebuildMode: Sendable {
    case resumeIfAvailable
    case fresh
}

public enum IndexActivityPresentation: String, Codable, Equatable, Sendable {
    case foreground
    case backgroundCatchUp
}

public enum IndexWorkPriority: String, Sendable {
    case interactive
    case background

    static func merged(_ lhs: IndexWorkPriority, _ rhs: IndexWorkPriority) -> IndexWorkPriority {
        lhs == .interactive || rhs == .interactive ? .interactive : .background
    }

    var maintenancePriority: IndexMaintenancePriority {
        switch self {
        case .interactive:
            .interactive
        case .background:
            .background
        }
    }
}

public enum ReconciliationRequestResult: Equatable, Sendable {
    case ignored
    case started
    case queued
    case coveredByActive
}

public struct IndexStats: Codable, Equatable, Sendable {
    public let indexedCount: Int
    public let isIndexing: Bool
    public let isReconciling: Bool
    public let isUpdating: Bool
    public let isLoadingSnapshot: Bool
    public let phase: IndexPhase
    public let discoveredCount: Int
    public let searchableCount: Int
    public let optimizedCount: Int
    public let snapshotRevision: UInt64
    public let status: String
    public let lastUpdated: Date
    public let activeOperationStartedAt: Date?
    public let lastCheckpointAt: Date?
    public let resumedFromCheckpoint: Bool
    public let activityPresentation: IndexActivityPresentation

    private enum CodingKeys: String, CodingKey {
        case indexedCount
        case isIndexing
        case isReconciling
        case isRefreshing
        case isUpdating
        case isLoadingSnapshot
        case phase
        case discoveredCount
        case searchableCount
        case optimizedCount
        case snapshotRevision
        case status
        case lastUpdated
        case activeOperationStartedAt
        case lastCheckpointAt
        case resumedFromCheckpoint
        case activityPresentation
    }

    public init(
        indexedCount: Int,
        isIndexing: Bool,
        isReconciling: Bool = false,
        isUpdating: Bool = false,
        isLoadingSnapshot: Bool = false,
        phase: IndexPhase? = nil,
        discoveredCount: Int? = nil,
        searchableCount: Int? = nil,
        optimizedCount: Int? = nil,
        snapshotRevision: UInt64 = 0,
        status: String,
        lastUpdated: Date,
        activeOperationStartedAt: Date? = nil,
        lastCheckpointAt: Date? = nil,
        resumedFromCheckpoint: Bool = false,
        activityPresentation: IndexActivityPresentation = .foreground
    ) {
        self.indexedCount = indexedCount
        self.isIndexing = isIndexing
        self.isReconciling = isReconciling
        self.isUpdating = isUpdating
        self.isLoadingSnapshot = isLoadingSnapshot
        self.phase = phase ?? (isLoadingSnapshot ? .loading : (isIndexing ? .scanning : .ready))
        self.discoveredCount = discoveredCount ?? indexedCount
        self.searchableCount = searchableCount ?? indexedCount
        self.optimizedCount = optimizedCount ?? (isIndexing ? 0 : indexedCount)
        self.snapshotRevision = snapshotRevision
        self.status = status
        self.lastUpdated = lastUpdated
        self.activeOperationStartedAt = activeOperationStartedAt
        self.lastCheckpointAt = lastCheckpointAt
        self.resumedFromCheckpoint = resumedFromCheckpoint
        self.activityPresentation = activityPresentation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let indexedCount = try container.decode(Int.self, forKey: .indexedCount)
        let isIndexing = try container.decode(Bool.self, forKey: .isIndexing)
        let isLoadingSnapshot = try container.decodeIfPresent(Bool.self, forKey: .isLoadingSnapshot) ?? false
        self.indexedCount = indexedCount
        self.isIndexing = isIndexing
        self.isReconciling = try container.decodeIfPresent(Bool.self, forKey: .isReconciling)
            ?? container.decodeIfPresent(Bool.self, forKey: .isRefreshing)
            ?? false
        self.isUpdating = try container.decodeIfPresent(Bool.self, forKey: .isUpdating) ?? false
        self.isLoadingSnapshot = isLoadingSnapshot
        self.phase = try container.decodeIfPresent(IndexPhase.self, forKey: .phase)
            ?? (isLoadingSnapshot ? .loading : (isIndexing ? .scanning : .ready))
        self.discoveredCount = try container.decodeIfPresent(Int.self, forKey: .discoveredCount) ?? indexedCount
        self.searchableCount = try container.decodeIfPresent(Int.self, forKey: .searchableCount) ?? indexedCount
        self.optimizedCount = try container.decodeIfPresent(Int.self, forKey: .optimizedCount) ?? (isIndexing ? 0 : indexedCount)
        self.snapshotRevision = try container.decodeIfPresent(UInt64.self, forKey: .snapshotRevision) ?? 0
        self.status = try container.decode(String.self, forKey: .status)
        self.lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)
        self.activeOperationStartedAt = try container.decodeIfPresent(Date.self, forKey: .activeOperationStartedAt)
        self.lastCheckpointAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckpointAt)
        self.resumedFromCheckpoint = try container.decodeIfPresent(Bool.self, forKey: .resumedFromCheckpoint) ?? false
        self.activityPresentation = try container.decodeIfPresent(IndexActivityPresentation.self, forKey: .activityPresentation) ?? .foreground
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(indexedCount, forKey: .indexedCount)
        try container.encode(isIndexing, forKey: .isIndexing)
        try container.encode(isReconciling, forKey: .isReconciling)
        try container.encode(isUpdating, forKey: .isUpdating)
        try container.encode(isLoadingSnapshot, forKey: .isLoadingSnapshot)
        try container.encode(phase, forKey: .phase)
        try container.encode(discoveredCount, forKey: .discoveredCount)
        try container.encode(searchableCount, forKey: .searchableCount)
        try container.encode(optimizedCount, forKey: .optimizedCount)
        try container.encode(snapshotRevision, forKey: .snapshotRevision)
        try container.encode(status, forKey: .status)
        try container.encode(lastUpdated, forKey: .lastUpdated)
        try container.encodeIfPresent(activeOperationStartedAt, forKey: .activeOperationStartedAt)
        try container.encodeIfPresent(lastCheckpointAt, forKey: .lastCheckpointAt)
        try container.encode(resumedFromCheckpoint, forKey: .resumedFromCheckpoint)
        try container.encode(activityPresentation, forKey: .activityPresentation)
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
    let pathGramCoveredRowCount: Int
    let pathGramTotalRowCount: Int
    let nameGramKeyCount: Int
    let nameGramPostingCount: Int
    let componentGramKeyCount: Int
    let componentGramPostingCount: Int
    let extensionKeyCount: Int
    let extensionPostingCount: Int
    let compositeSearchSegmentCount: Int
    let compositeMaskedRowCount: Int
    let pendingRefreshPathCount: Int
    let pendingBackgroundRefreshPathCount: Int
    let completedRefreshBatches: UInt64
    let completedSnapshotRebuilds: UInt64
    let activeIndexJobs: Int
    let schemaVersion: Int
    let resultCount: Int
    let virtualRowCount: Int
    let fallbackScanCount: UInt64
    let scannedRowCount: UInt64
    let pathMaterializationCount: UInt64
    let lastCheckpointAt: Date?
    let resumedFromCheckpoint: Bool
    let scanFrontierMetrics: ScanFrontierMetrics
}

struct FileIndexMemoryTelemetryEvent: Sendable {
    let event: String
    let recordCount: Int
    let totalPathBytes: Int
    let maxPathBytes: Int
    let storeKind: RecordStoreKind?
    let mappedByteSize: Int
    let heapPageCount: Int
    let overlayCount: Int
    let pathGramKeyCount: Int
    let pathGramPostingCount: Int
    let nameGramKeyCount: Int
    let nameGramPostingCount: Int
    let componentGramKeyCount: Int
    let componentGramPostingCount: Int
    let extensionKeyCount: Int
    let extensionPostingCount: Int
    let scopeCount: Int
    let reconcilesAllRoots: Bool?
    let refreshBatchSize: Int
    let activeIndexJobs: Int
    let residentBytes: UInt64
    let physicalFootprintBytes: UInt64
    let virtualBytes: UInt64
}

enum ExclusionEvaluationMode: String, Sendable, CaseIterable {
    case compiledQuery
    case legacyRules
}

enum ScanFrontierMode: String, Sendable, CaseIterable {
    case singleDirectory
    case batchedEnqueue
    case batchedClaim
    case batchedClaimAndEnqueue

    var usesBatchedClaim: Bool {
        self == .batchedClaim || self == .batchedClaimAndEnqueue
    }

    var usesBatchedEnqueue: Bool {
        self == .batchedEnqueue || self == .batchedClaimAndEnqueue
    }
}

struct ScanFrontierMetrics: Sendable, Equatable {
    var enqueueCallCount: UInt64 = 0
    var enqueuedDirectoryCount: UInt64 = 0
    var claimCallCount: UInt64 = 0
    var claimedDirectoryCount: UInt64 = 0
    var finishCallCount: UInt64 = 0
    var finishedDirectoryCount: UInt64 = 0
    var maxPendingDirectoryCount: Int = 0
    var maxActiveDirectoryCount: Int = 0
    var appendCallCount: UInt64 = 0
    var appendedRecordCount: UInt64 = 0
    var searchableSnapshotCount: UInt64 = 0
    var searchableSnapshotRowCount: UInt64 = 0
    var checkpointSnapshotCount: UInt64 = 0
    var checkpointSnapshotRowCount: UInt64 = 0
    var finalSnapshotCount: UInt64 = 0
    var finalSnapshotRowCount: UInt64 = 0
    var retainedRecordDictionaryCount: Int = 0
}

struct ScanCheckpointSchedule: Sendable {
    private let operationStartedAt: Date
    private let minimumElapsedInterval: TimeInterval
    private let initialRecordInterval: Int
    private let initialTimeInterval: TimeInterval
    private let subsequentRecordInterval: Int
    private let subsequentTimeInterval: TimeInterval
    private(set) var lastCheckpointCount = 0
    private(set) var lastCheckpointAt: Date?

    init(
        operationStartedAt: Date,
        lastCheckpointCount: Int = 0,
        lastCheckpointAt: Date? = nil,
        minimumElapsedInterval: TimeInterval = 60,
        initialRecordInterval: Int = 25_000,
        initialTimeInterval: TimeInterval = 60,
        subsequentRecordInterval: Int = 100_000,
        subsequentTimeInterval: TimeInterval = 300
    ) {
        self.operationStartedAt = operationStartedAt
        self.minimumElapsedInterval = max(minimumElapsedInterval, 0)
        self.initialRecordInterval = max(initialRecordInterval, 1)
        self.initialTimeInterval = max(initialTimeInterval, 0)
        self.subsequentRecordInterval = max(subsequentRecordInterval, 1)
        self.subsequentTimeInterval = max(subsequentTimeInterval, 0)
        self.lastCheckpointCount = max(lastCheckpointCount, 0)
        self.lastCheckpointAt = lastCheckpointAt
    }

    mutating func shouldCreateCheckpoint(recordCount: Int, at now: Date, force: Bool = false) -> Bool {
        let recordCount = max(recordCount, 0)
        if force {
            recordCheckpoint(recordCount: recordCount, at: now)
            return true
        }

        let addedRecordCount = recordCount - lastCheckpointCount
        guard addedRecordCount > 0 else { return false }

        let previousDate = lastCheckpointAt ?? operationStartedAt
        let elapsed = now.timeIntervalSince(previousDate)
        guard elapsed >= minimumElapsedInterval else { return false }

        let recordInterval = lastCheckpointAt == nil ? initialRecordInterval : subsequentRecordInterval
        let timeInterval = lastCheckpointAt == nil ? initialTimeInterval : subsequentTimeInterval
        guard addedRecordCount >= recordInterval || elapsed >= timeInterval else { return false }

        recordCheckpoint(recordCount: recordCount, at: now)
        return true
    }

    private mutating func recordCheckpoint(recordCount: Int, at date: Date) {
        lastCheckpointCount = recordCount
        lastCheckpointAt = date
    }
}

public final class FileIndex: @unchecked Sendable {
    private static let maximumRefreshBatchPaths = 512
    private static let primaryPublishRecordInterval = 25_000
    private static let primaryPublishTimeInterval: TimeInterval = 1
    private static let scanStatusPublishRecordInterval = 1_000
    private static let scanStatusPublishTimeInterval: TimeInterval = 0.25
    private static let pathGramRecordLimit = 200_000
    private static let pathGramShardSize = 2_048
    private static let pathGramTotalPathByteLimit = 24 * 1024 * 1024
    private static let defaultDeferredOptimizationRecordThreshold = 10_000
    private static let exactEmptyQuerySortLimit = 100_000
    private static let largeOverlayPersistDefaultDelay: TimeInterval = 30
    private static let largeOverlayChangedPathDefaultThreshold = 10_000
    private static let largeOverlayDrainBackoffDefaultDelay: TimeInterval = 5
    // Exact FSEvent bursts are cheaper and more energy-efficient when structural
    // delta rewrites are amortized across the largest already-bounded batch.
    private static let backgroundRefreshBatchDefaultLimit = maximumRefreshBatchPaths
    private static let backgroundRefreshDrainBackoffDefaultDelay: TimeInterval = 60
    private static let backgroundRefreshRetryMaximumDelay: TimeInterval = 60 * 60
    private static let fullScanRetryLimit = 3
    private static let backgroundDirectoryScanBudgetDefault: TimeInterval = 1.5
    private static let backgroundDirectoryScanVisitDefaultLimit = 2_048
    private static let backgroundDirectoryScanEntryDefaultLimit = 8_192
    private static let backgroundDirectoryFinalizationDefaultLimit = 1_048_576
    private static let directoryFinalizationCursorBatchSize = 4_096
    private static let backgroundDirectoryIncrementalPublishLimit = 2_048
    private static let backgroundDirectoryIncrementalPublishBatchLimit = 4
    private static let backgroundOptimizationPersistDefaultDelay: TimeInterval = 300
    private static let structuralDeltaCompactionWriterConflictWarningDelay: TimeInterval = 15 * 60
    private static let structuralDeltaCompactionRetryDelay: TimeInterval = 30
    private static let structuralDeltaCompactionImmediateChangeMultiplier = 4
    private static let structuralDeltaCompactionImmediateByteLimit: UInt64 = 64 * 1_024 * 1_024
    private static let metadataOverlayPersistDefaultDelay: TimeInterval = 30
    private static let metadataOverlayCheckpointDefaultDelay: TimeInterval = 300
    private static let metadataOverlayPersistDefaultLimit = 10_000
    private static let usageMetricsMaintenanceSaveDefaultDelay: TimeInterval = 5 * 60
    private static let interactiveOverlayOptimizationRecordLimit = 25_000
    private static let degradedSearchMaximumScanLimit = 25_000
    private static let previewIndexedCandidateScanLimit = 50_000
    private static let previewOrderedCandidateScanLimit = 25_000
    private static let pendingRefreshSearchResultLimit = 64

#if DEBUG
    static var defaultBackgroundDirectoryMaintenancePolicyForTesting: (
        scanBudget: TimeInterval,
        backoff: TimeInterval,
        visitLimit: Int,
        entryLimit: Int,
        targetDutyCycle: Double
    ) {
        let scanBudget = backgroundDirectoryScanBudgetDefault
        let backoff = backgroundRefreshDrainBackoffDefaultDelay
        return (
            scanBudget,
            backoff,
            backgroundDirectoryScanVisitDefaultLimit,
            backgroundDirectoryScanEntryDefaultLimit,
            scanBudget / (scanBudget + backoff)
        )
    }
#endif

    public static let maximumIndexedRootCount = RootAttributionTable.maximumRootCount
    private static let memoryTelemetrySinkForTesting = MemoryTelemetrySinkBox()

    private static func sortOrderFileName(for column: SortColumn) -> String? {
        switch column {
        case .relevance:
            return nil
        case .name:
            return SnapshotLayout.FileName.nameOrder
        case .path:
            return SnapshotLayout.FileName.pathOrder
        case .modified:
            return SnapshotLayout.FileName.modifiedOrder
        case .created:
            return SnapshotLayout.FileName.createdOrder
        case .size:
            return SnapshotLayout.FileName.sizeOrder
        case .fileExtension:
            return SnapshotLayout.FileName.extensionOrder
        case .kind:
            return SnapshotLayout.FileName.kindOrder
        case .volume:
            return SnapshotLayout.FileName.volumeOrder
        case .root:
            return SnapshotLayout.FileName.rootOrder
        }
    }

    private final class MemoryTelemetrySinkBox: @unchecked Sendable {
        private let lock = NSLock()
        private var sink: (@Sendable (FileIndexMemoryTelemetryEvent) -> Void)?

        func set(_ sink: (@Sendable (FileIndexMemoryTelemetryEvent) -> Void)?) {
            lock.withLock {
                self.sink = sink
            }
        }

        func emit(_ event: FileIndexMemoryTelemetryEvent) {
            let sink = lock.withLock { self.sink }
            sink?(event)
        }
    }

    static func setMemoryTelemetrySinkForTesting(_ sink: (@Sendable (FileIndexMemoryTelemetryEvent) -> Void)?) {
        memoryTelemetrySinkForTesting.set(sink)
    }

    private static func emitMemoryTelemetryForTesting(_ event: FileIndexMemoryTelemetryEvent) {
        memoryTelemetrySinkForTesting.emit(event)
    }

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

    public var onBackgroundReconciliationRequested: (@MainActor @Sendable ([URL]) -> Void)? {
        get {
            lock.withLock {
                backgroundReconciliationHandler
            }
        }
        set {
            lock.withLock {
                backgroundReconciliationHandler = newValue
            }
        }
    }

    public func setPublishesSearchableSnapshotsDuringScan(_ enabled: Bool) {
        lock.withLock {
            publishesSearchableSnapshotsDuringScan = enabled
        }
    }

    private struct LoadedMappedSnapshot {
        let manifest: CompactSnapshotManifest
        let store: MappedRecordStore
        let searchStructures: PersistedSearchStructures
    }

    private struct LoadedStructuralSnapshot {
        let snapshot: SearchSnapshot
        let delta: StructuralDelta?
        let optimizedFallback: SearchSnapshot?
        let compositeSearchState: CompositeSearchState?
        let requiresFullReconciliation: Bool
    }

    private struct ScanCheckpointState: Codable, Sendable {
        let schemaVersion: Int
        let savedAt: Date
        let operationStartedAt: Date
        let roots: [String]
        let exclusionPatterns: [String]
        let pendingDirectories: [String]
        let activeDirectories: [String]
        let completedDirectories: [String]
        let discoveredCount: Int
        let recordCount: Int

        var resumableDirectories: [String] {
            pendingDirectories + activeDirectories
        }
    }

    private struct LoadedScanCheckpoint {
        let state: ScanCheckpointState
        let store: MappedRecordStore
        let searchStructures: PersistedSearchStructures
    }

    /// Component searches cover both real result rows and virtual directory rows.
    /// New snapshots share one all-row index with name search; the combined case
    /// keeps snapshots written by older versions readable.
    private enum ComponentGramPostingIndex: @unchecked Sendable {
        case combined(MappedIntPostingIndex)
        case shared(MappedIntPostingIndex)

        var keyCount: Int {
            switch self {
            case .combined(let index):
                return index.keyCount
            case .shared(let index):
                return index.keyCount
            }
        }

        var postingCount: Int {
            switch self {
            case .combined(let index):
                return index.postingCount
            case .shared(let index):
                return index.postingCount
            }
        }
    }

    private struct PersistedSearchStructures {
        let modifiedDescending: [Int]?
        let visibleModifiedDescending: [Int]?
        let sortOrdersAscending: [SortColumn: [Int]]
        let nameGramIndex: MappedIntPostingIndex?
        let componentGramIndex: ComponentGramPostingIndex?
        let pathGramIndex: MappedIntPostingIndex?

        static let empty = PersistedSearchStructures(
            modifiedDescending: nil,
            visibleModifiedDescending: nil,
            sortOrdersAscending: [:],
            nameGramIndex: nil,
            componentGramIndex: nil,
            pathGramIndex: nil
        )
    }

    private struct PersistedMetadataOverlay {
        private static let magic: UInt64 = 0x314c41574d545441 // ATTMWAL1 little-endian bytes.
        private static let currentSchemaVersion: UInt32 = 1
        private static let headerSize = 40
        private static let maximumStringByteCount = 16 * 1024 * 1024

        let baseSnapshotSchemaVersion: Int
        let baseRecordCount: Int
        let baseSavedAt: Date
        let savedAt: Date
        let replacements: [FileRecord]

        init(
            baseSnapshotSchemaVersion: Int,
            baseRecordCount: Int,
            baseSavedAt: Date,
            replacements: [FileRecord],
            savedAt: Date = Date()
        ) {
            self.baseSnapshotSchemaVersion = baseSnapshotSchemaVersion
            self.baseRecordCount = baseRecordCount
            self.baseSavedAt = baseSavedAt
            self.savedAt = savedAt
            self.replacements = replacements
        }

        func encodedData() throws -> Data {
            guard
                baseSnapshotSchemaVersion >= 0,
                baseSnapshotSchemaVersion <= Int(UInt32.max),
                baseRecordCount >= 0
            else {
                throw CocoaError(.fileWriteUnknown)
            }

            var data = Data()
            data.reserveCapacity(Self.headerSize + replacements.count * 128)
            data.appendUInt64LE(Self.magic)
            data.appendUInt32LE(Self.currentSchemaVersion)
            data.appendUInt32LE(UInt32(baseSnapshotSchemaVersion))
            data.appendUInt64LE(UInt64(baseRecordCount))
            data.appendUInt64LE(baseSavedAt.timeIntervalSinceReferenceDate.bitPattern)
            data.appendUInt64LE(savedAt.timeIntervalSinceReferenceDate.bitPattern)
            data.appendUInt64LE(UInt64(replacements.count))

            for record in replacements {
                try Self.append(record, to: &data)
            }

            return data
        }

        static func decode(from data: Data) throws -> PersistedMetadataOverlay {
            var reader = MetadataOverlayReader(data: data)
            let magic = try reader.readUInt64()
            let version = try reader.readUInt32()
            let baseSnapshotSchemaVersion = try reader.readUInt32()
            let baseRecordCount = try reader.readUInt64()
            let baseSavedAtBits = try reader.readUInt64()
            let savedAtBits = try reader.readUInt64()
            let replacementCount = try reader.readUInt64()

            guard magic == Self.magic, version == Self.currentSchemaVersion else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard baseRecordCount <= UInt64(Int.max), replacementCount <= UInt64(Int.max) else {
                throw CocoaError(.fileReadCorruptFile)
            }

            var replacements: [FileRecord] = []
            replacements.reserveCapacity(Int(replacementCount))
            for _ in 0..<Int(replacementCount) {
                replacements.append(try Self.readRecord(from: &reader))
            }
            guard reader.isAtEnd else {
                throw CocoaError(.fileReadCorruptFile)
            }

            return PersistedMetadataOverlay(
                baseSnapshotSchemaVersion: Int(baseSnapshotSchemaVersion),
                baseRecordCount: Int(baseRecordCount),
                baseSavedAt: Date(timeIntervalSinceReferenceDate: TimeInterval(bitPattern: baseSavedAtBits)),
                replacements: replacements,
                savedAt: Date(timeIntervalSinceReferenceDate: TimeInterval(bitPattern: savedAtBits))
            )
        }

        private static func append(_ record: FileRecord, to data: inout Data) throws {
            var flags: UInt32 = 0
            if record.isDirectory { flags |= 1 }
            if record.isHidden { flags |= 2 }
            if record.createdTime != nil { flags |= 4 }

            data.appendUInt64LE(record.id)
            data.appendUInt32LE(flags)
            data.appendUInt64LE(record.sizeBytes)
            data.appendUInt64LE(record.modifiedTime.bitPattern)
            data.appendUInt64LE((record.createdTime ?? 0).bitPattern)
            try data.appendLengthPrefixedUTF8(record.path, maximumByteCount: maximumStringByteCount)
            try data.appendLengthPrefixedUTF8(record.name, maximumByteCount: maximumStringByteCount)
            try data.appendLengthPrefixedUTF8(record.directoryPath, maximumByteCount: maximumStringByteCount)
            try data.appendLengthPrefixedUTF8(record.fileExtension, maximumByteCount: maximumStringByteCount)
            try data.appendLengthPrefixedUTF8(record.volumeName, maximumByteCount: maximumStringByteCount)
            try data.appendLengthPrefixedUTF8(record.normalizedName, maximumByteCount: maximumStringByteCount)
            try data.appendLengthPrefixedUTF8(record.normalizedPath, maximumByteCount: maximumStringByteCount)
        }

        private static func readRecord(from reader: inout MetadataOverlayReader) throws -> FileRecord {
            let id = try reader.readUInt64()
            let flags = try reader.readUInt32()
            let sizeBytes = try reader.readUInt64()
            let modifiedTime = TimeInterval(bitPattern: try reader.readUInt64())
            let createdBits = try reader.readUInt64()
            let path = try reader.readString(maximumByteCount: maximumStringByteCount)
            let name = try reader.readString(maximumByteCount: maximumStringByteCount)
            let directoryPath = try reader.readString(maximumByteCount: maximumStringByteCount)
            let fileExtension = try reader.readString(maximumByteCount: maximumStringByteCount)
            let volumeName = try reader.readString(maximumByteCount: maximumStringByteCount)
            let normalizedName = try reader.readString(maximumByteCount: maximumStringByteCount)
            let normalizedPath = try reader.readString(maximumByteCount: maximumStringByteCount)

            return FileRecord(
                id: id,
                path: path,
                name: name,
                directoryPath: directoryPath,
                fileExtension: fileExtension,
                sizeBytes: sizeBytes,
                modifiedTime: modifiedTime,
                createdTime: flags & 4 == 0 ? nil : TimeInterval(bitPattern: createdBits),
                isDirectory: flags & 1 != 0,
                isHidden: flags & 2 != 0,
                volumeName: volumeName,
                normalizedName: normalizedName,
                normalizedPath: normalizedPath
            )
        }
    }

    private struct MetadataOverlayReader {
        private let data: Data
        private var offset = 0

        init(data: Data) {
            self.data = data
        }

        var isAtEnd: Bool {
            offset == data.count
        }

        mutating func readUInt32() throws -> UInt32 {
            guard offset + 4 <= data.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let value = UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
            offset += 4
            return value
        }

        mutating func readUInt64() throws -> UInt64 {
            guard offset + 8 <= data.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var value: UInt64 = 0
            for index in 0..<8 {
                value |= UInt64(data[offset + index]) << UInt64(index * 8)
            }
            offset += 8
            return value
        }

        mutating func readString(maximumByteCount: Int) throws -> String {
            let length = try readUInt32()
            guard length <= UInt32(maximumByteCount), UInt64(length) <= UInt64(data.count - offset) else {
                throw CocoaError(.fileReadCorruptFile)
            }

            let end = offset + Int(length)
            guard let value = String(data: Data(data[offset..<end]), encoding: .utf8) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            offset = end
            return value
        }
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
        let pathGramCoveredRowCount: Int
        let pathGramTotalRowCount: Int
        let nameGramKeyCount: Int
        let nameGramPostingCount: Int
        let componentGramKeyCount: Int
        let componentGramPostingCount: Int
        let extensionKeyCount: Int
        let extensionPostingCount: Int
        let simdTextVerificationEnabled: Bool
    }

    private struct MemoryTelemetryContext {
        let scopeCount: Int
        let reconcilesAllRoots: Bool?

        static let none = MemoryTelemetryContext(scopeCount: 0, reconcilesAllRoots: nil)
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
            store: RecordStore? = nil,
            refreshBatchSize: Int = 0,
            activeIndexJobs: Int = 0,
            context: MemoryTelemetryContext = .none
        ) {
            os_signpost(.event, log: signpostLog, name: "IndexMemory")
            let memory = currentMemory()
            let storeKind = store?.kind.rawValue ?? ""
            let reconcilesAllRoots = context.reconcilesAllRoots.map { $0 ? "true" : "false" } ?? "unknown"
            let telemetryEvent = FileIndexMemoryTelemetryEvent(
                event: event,
                recordCount: records?.recordCount ?? 0,
                totalPathBytes: records?.totalPathBytes ?? 0,
                maxPathBytes: records?.maxPathBytes ?? 0,
                storeKind: store?.kind,
                mappedByteSize: store?.mappedByteSize ?? 0,
                heapPageCount: store?.heapPageCount ?? 0,
                overlayCount: store?.overlayCount ?? 0,
                pathGramKeyCount: structures?.pathGramKeyCount ?? 0,
                pathGramPostingCount: structures?.pathGramPostingCount ?? 0,
                nameGramKeyCount: structures?.nameGramKeyCount ?? 0,
                nameGramPostingCount: structures?.nameGramPostingCount ?? 0,
                componentGramKeyCount: structures?.componentGramKeyCount ?? 0,
                componentGramPostingCount: structures?.componentGramPostingCount ?? 0,
                extensionKeyCount: structures?.extensionKeyCount ?? 0,
                extensionPostingCount: structures?.extensionPostingCount ?? 0,
                scopeCount: context.scopeCount,
                reconcilesAllRoots: context.reconcilesAllRoots,
                refreshBatchSize: refreshBatchSize,
                activeIndexJobs: activeIndexJobs,
                residentBytes: memory?.residentBytes ?? 0,
                physicalFootprintBytes: memory?.physicalFootprintBytes ?? 0,
                virtualBytes: memory?.virtualBytes ?? 0
            )
            FileIndex.emitMemoryTelemetryForTesting(telemetryEvent)
            logger.info(
                """
                event=\(event, privacy: .public) \
                records=\(records?.recordCount ?? 0, privacy: .public) \
                totalPathBytes=\(records?.totalPathBytes ?? 0, privacy: .public) \
                maxPathBytes=\(records?.maxPathBytes ?? 0, privacy: .public) \
                storeKind=\(storeKind, privacy: .public) \
                mappedByteSize=\(store?.mappedByteSize ?? 0, privacy: .public) \
                heapPageCount=\(store?.heapPageCount ?? 0, privacy: .public) \
                overlayCount=\(store?.overlayCount ?? 0, privacy: .public) \
                pathGramKeys=\(structures?.pathGramKeyCount ?? 0, privacy: .public) \
                pathGramPostings=\(structures?.pathGramPostingCount ?? 0, privacy: .public) \
                nameGramKeys=\(structures?.nameGramKeyCount ?? 0, privacy: .public) \
                nameGramPostings=\(structures?.nameGramPostingCount ?? 0, privacy: .public) \
                extensionKeys=\(structures?.extensionKeyCount ?? 0, privacy: .public) \
                extensionPostings=\(structures?.extensionPostingCount ?? 0, privacy: .public) \
                scopeCount=\(context.scopeCount, privacy: .public) \
                reconcilesAllRoots=\(reconcilesAllRoots, privacy: .public) \
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

    private struct RankedSearchMatch {
        let rank: Int32
        let match: SearchMatch
    }

    private struct RefreshUpdateResult {
        let applied: Bool
        let completionReady: Bool
        let largeOverlay: Bool
        let priority: IndexWorkPriority
        let requestedDirectoryRefresh: Bool
        let batchPathCount: Int
        let changedPathCount: Int
        let visitedCount: Int
        let exclusionInstrumentation: FileExclusionQuery.Instrumentation
        let reconciledDirectoryPrefixes: [String]
        let deferredRefreshes: [PendingRefreshWork]
        let completedRefreshes: [PendingRefreshWork]
        let deferredDirectoryVisitCount: Int

        static let none = RefreshUpdateResult(
            applied: false,
            completionReady: false,
            largeOverlay: false,
            priority: .interactive,
            requestedDirectoryRefresh: false,
            batchPathCount: 0,
            changedPathCount: 0,
            visitedCount: 0,
            exclusionInstrumentation: FileExclusionQuery.Instrumentation(),
            reconciledDirectoryPrefixes: [],
            deferredRefreshes: [],
            completedRefreshes: [],
            deferredDirectoryVisitCount: 0
        )
    }

    private final class PendingRefreshCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var remainingPathCount: Int
        private var didComplete = false
        private let completion: @Sendable () -> Void

        init(pathCount: Int, completion: @escaping @Sendable () -> Void) {
            remainingPathCount = max(pathCount, 0)
            self.completion = completion
        }

        func addPathDependency() -> Bool {
            lock.withLock {
                guard !didComplete else { return false }
                remainingPathCount += 1
                return true
            }
        }

        func completeOnePath() {
            let shouldComplete = lock.withLock { () -> Bool in
                guard !didComplete else { return false }
                remainingPathCount -= 1
                guard remainingPathCount <= 0 else { return false }
                didComplete = true
                return true
            }

            if shouldComplete {
                completion()
            }
        }
    }

    private final class DirectoryUpdateEnumerationCursor: @unchecked Sendable {
        let directory: URL
        let directoryPath: String
        private(set) var stream: UnsafeMutablePointer<DIR>?
        var children: [URL] = []
        var readEntryCount = 0

        init(directory: URL, stream: UnsafeMutablePointer<DIR>) {
            self.directory = directory
            self.directoryPath = directory.path
            self.stream = stream
        }

        func close() {
            guard let stream else { return }
            closedir(stream)
            self.stream = nil
        }

        func takeChildrenAndClose() -> [URL] {
            close()
            let result = children
            self.children.removeAll(keepingCapacity: false)
            return result
        }

        deinit {
            close()
        }
    }

    private final class DirectoryUpdateScanProgress: @unchecked Sendable {
        let rootPath: String
        let baselineStore: RecordStore
        var pendingURLs: [URL]
        var deferredRetryURLs: [URL] = []
        var activeEnumeration: DirectoryUpdateEnumerationCursor?
        var seenBaselineRows: PackedRowBitSet
        var scannedRecordCount = 0
        var unpublishedRecords: [String: FileRecord] = [:]
        var incrementallyPublishedChangeCount = 0
        var incrementalPublishBatchCount = 0
        var finalization: DirectoryUpdateFinalization?
        var traversalWorkCount = 0
        private(set) var supersededPrefixes: [String] = []

        init(root: URL, baselineStore: RecordStore) {
            rootPath = root.standardizedFileURL.path
            self.baselineStore = baselineStore
            seenBaselineRows = PackedRowBitSet(bitCount: baselineStore.count)
            pendingURLs = [root]
        }

        func recordObservedPath(_ path: String) {
            scannedRecordCount += 1
            guard let rowID = baselineStore.rowID(forPath: path) else { return }
            seenBaselineRows.insert(rowID)
        }

        func recordMissingPath(_ path: String) {
            guard let rowID = baselineStore.rowID(forPath: path) else { return }
            seenBaselineRows.remove(rowID)
        }

        func activateDeferredRetriesIfNeeded() {
            guard activeEnumeration == nil,
                  pendingURLs.isEmpty,
                  !deferredRetryURLs.isEmpty else {
                return
            }
            pendingURLs = deferredRetryURLs
            deferredRetryURLs.removeAll(keepingCapacity: true)
        }

        func deferForRetry(_ url: URL) {
            deferredRetryURLs.append(url)
        }

        @discardableResult
        func supersedeSubtree(at path: String) -> Bool {
            guard path != rootPath,
                  (rootPath == "/" ? path.hasPrefix("/") : path.hasPrefix(rootPath + "/")),
                  !isSuperseded(path) else {
                return false
            }

            supersededPrefixes.removeAll { Self.contains($0, in: path) }
            supersededPrefixes.append(path)
            supersededPrefixes.sort()
            return true
        }

        func isSuperseded(_ path: String) -> Bool {
            var lowerBound = 0
            var upperBound = supersededPrefixes.count
            while lowerBound < upperBound {
                let middle = lowerBound + (upperBound - lowerBound) / 2
                if supersededPrefixes[middle] <= path {
                    lowerBound = middle + 1
                } else {
                    upperBound = middle
                }
            }
            guard lowerBound > 0 else { return false }
            return Self.contains(path, in: supersededPrefixes[lowerBound - 1])
        }

        private static func contains(_ path: String, in prefix: String) -> Bool {
            path == prefix || (prefix == "/" ? path.hasPrefix("/") : path.hasPrefix(prefix + "/"))
        }
    }

    private enum DirectoryUpdateFinalizationPhase: String, Sendable {
        case baselineRows
        case unpublishedUpserts
        case readyToCommit
    }

    private final class DirectoryUpdateFinalization: @unchecked Sendable {
        var baselineCursor: RecordStoreSubtreeCursor
        let unpublishedRecords: [String: FileRecord]
        var unpublishedRecordIndex: Dictionary<String, FileRecord>.Index
        var phase = DirectoryUpdateFinalizationPhase.baselineRows
        var deletionPaths: [String] = []
        var preparedUpsertPaths: [String] = []
        var baselineRowsVisited = 0
        var matchingBaselineRowsVisited = 0
        var upsertsVisited = 0
        var materializedDeletionPathCount = 0

        init(progress: DirectoryUpdateScanProgress) {
            baselineCursor = progress.baselineStore.makeSubtreeRowCursor(atPath: progress.rootPath)
            let unpublishedRecords = progress.unpublishedRecords
            self.unpublishedRecords = unpublishedRecords
            unpublishedRecordIndex = unpublishedRecords.startIndex
            progress.unpublishedRecords.removeAll(keepingCapacity: false)
        }
    }

    private struct DirectoryUpdateFinalizationResult {
        let completed: Bool
        let visitedCount: Int
    }

    private struct PendingRefreshWork: Sendable {
        let path: String
        var priority: IndexWorkPriority
        var recursivelyScansDirectory: Bool
        var followUpRecursivelyScansDirectory: Bool
        var firstQueuedAt: Date
        var completions: [PendingRefreshCompletion]
        var followUpCompletions: [PendingRefreshCompletion]
        var directoryScanProgress: DirectoryUpdateScanProgress?
        var requiresDirectoryRescanAfterProgress: Bool
        var eligibleAt: Date?
        var lastServiceSequence: UInt64?
        var retryAttempt: Int

        mutating func merge(_ incoming: PendingRefreshWork) {
            // Keep partial traversal state stable; a fresh event is satisfied by one
            // clean follow-up pass after the current traversal reaches its boundary.
            let progressCollidedWithFreshRequest = (directoryScanProgress == nil)
                != (incoming.directoryScanProgress == nil)
            let breaksRetryBackoff = incoming.priority == .interactive
                && incoming.retryAttempt == 0
            priority = IndexWorkPriority.merged(priority, incoming.priority)
            firstQueuedAt = min(firstQueuedAt, incoming.firstQueuedAt)
            if directoryScanProgress != nil, incoming.directoryScanProgress == nil {
                followUpRecursivelyScansDirectory = followUpRecursivelyScansDirectory
                    || incoming.recursivelyScansDirectory
                    || incoming.followUpRecursivelyScansDirectory
                followUpCompletions.append(contentsOf: incoming.completions)
                followUpCompletions.append(contentsOf: incoming.followUpCompletions)
            } else {
                recursivelyScansDirectory = recursivelyScansDirectory
                    || incoming.recursivelyScansDirectory
                followUpRecursivelyScansDirectory = followUpRecursivelyScansDirectory
                    || incoming.followUpRecursivelyScansDirectory
                completions.append(contentsOf: incoming.completions)
                followUpCompletions.append(contentsOf: incoming.followUpCompletions)
            }
            requiresDirectoryRescanAfterProgress = requiresDirectoryRescanAfterProgress
                || incoming.requiresDirectoryRescanAfterProgress
                || progressCollidedWithFreshRequest
            if directoryScanProgress == nil {
                directoryScanProgress = incoming.directoryScanProgress
            }
            retryAttempt = max(retryAttempt, incoming.retryAttempt)
            if breaksRetryBackoff {
                eligibleAt = nil
                retryAttempt = 0
            } else if let incomingEligibleAt = incoming.eligibleAt {
                eligibleAt = max(eligibleAt ?? incomingEligibleAt, incomingEligibleAt)
            }
            if let incomingSequence = incoming.lastServiceSequence {
                lastServiceSequence = max(lastServiceSequence ?? incomingSequence, incomingSequence)
            }
        }

        mutating func prepareForFollowUpDirectoryScan() {
            directoryScanProgress = nil
            requiresDirectoryRescanAfterProgress = false
            recursivelyScansDirectory = followUpRecursivelyScansDirectory
            followUpRecursivelyScansDirectory = false
            completions = followUpCompletions
            followUpCompletions.removeAll(keepingCapacity: false)
        }

        mutating func promote() {
            priority = .interactive
            eligibleAt = nil
            retryAttempt = 0
        }

        mutating func demote() {
            priority = .background
        }

        mutating func deferBackgroundWork(until date: Date) {
            guard priority == .background else { return }
            eligibleAt = max(eligibleAt ?? date, date)
        }

        func isEligible(at date: Date) -> Bool {
            eligibleAt.map { $0 <= date } ?? true
        }

        mutating func markServiced(sequence: UInt64) {
            lastServiceSequence = sequence
        }

        mutating func deferAfterRetryFailure(baseDelay: TimeInterval, now: Date = Date()) {
            let delay = FileIndex.backgroundRefreshRetryDelay(
                baseDelay: baseDelay,
                priorFailureCount: retryAttempt
            )
            retryAttempt = min(retryAttempt + 1, 63)
            let retryDate = now.addingTimeInterval(delay)
            eligibleAt = max(eligibleAt ?? retryDate, retryDate)
        }

        mutating func clearRetryBackoffAfterProgress() {
            retryAttempt = 0
            eligibleAt = nil
        }
    }

    private struct DirectoryUpdateScanResult {
        let records: [String: FileRecord]
        let completed: Bool
        let visitedCount: Int
        let readEntryCount: Int
        let encounteredRetryError: Bool
        let exclusionInstrumentation: FileExclusionQuery.Instrumentation
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
        let store: HeapPagedRecordStore?
        let reconciliationDelta: ReconciliationScanDelta?
        let recordCount: Int
        let visited: Int
        let yieldedSlices: Int
        let frontierMetrics: ScanFrontierMetrics
        let exclusionInstrumentation: FileExclusionQuery.Instrumentation
    }

    private struct ReconciliationScanDelta {
        let observedBaselineRows: PackedRowBitSet
        let upserts: [String: FileRecord]
        let recordCount: Int
    }

    /// Collects only the information needed to diff a reconciliation scan.
    /// Calls are serialized by `ConcurrentScanState`, so the million-row scan
    /// does not need a second lock or a dictionary containing every FileRecord.
    private final class ReconciliationScanAccumulator: @unchecked Sendable {
        private let baselineStore: RecordStore
        private var observedBaselineRows: PackedRowBitSet
        private var upserts: [String: FileRecord] = [:]
        private var recordCount = 0

        init(baselineStore: RecordStore) {
            self.baselineStore = baselineStore
            observedBaselineRows = PackedRowBitSet(bitCount: baselineStore.count)
            upserts.reserveCapacity(4_096)
        }

        @discardableResult
        func append(_ record: FileRecord) -> Bool {
            if let rowID = baselineStore.rowID(forPath: record.path) {
                let isFirstObservation = observedBaselineRows.insert(rowID)
                if FileIndex.storedRecord(baselineStore, at: rowID, matches: record) {
                    upserts.removeValue(forKey: record.path)
                } else {
                    upserts[record.path] = record
                }
                if isFirstObservation {
                    recordCount += 1
                }
                return isFirstObservation
            }

            let isFirstObservation = upserts.updateValue(record, forKey: record.path) == nil
            if isFirstObservation {
                recordCount += 1
            }
            return isFirstObservation
        }

        func result() -> ReconciliationScanDelta {
            ReconciliationScanDelta(
                observedBaselineRows: observedBaselineRows,
                upserts: upserts,
                recordCount: recordCount
            )
        }
    }

    private struct MaintenanceMeasurement {
        let startedAt: Date
        let startingCPUTime: TimeInterval

        init(startedAt: Date = Date()) {
            self.startedAt = startedAt
            self.startingCPUTime = Self.currentProcessCPUTime()
        }

        func operation(
            kind: IndexMaintenanceOperationKind,
            priority: IndexMaintenancePriority,
            completedAt: Date = Date(),
            paths: Int = 0,
            records: Int = 0,
            visited: Int = 0,
            yieldedSlices: Int = 0,
            deferredPaths: Int = 0,
            largeOverlays: Int = 0,
            optimizationDeferrals: Int = 0,
            exclusionInstrumentation: FileExclusionQuery.Instrumentation = FileExclusionQuery.Instrumentation()
        ) -> IndexMaintenanceOperationMetric {
            IndexMaintenanceOperationMetric(
                kind: kind,
                priority: priority,
                completedAt: completedAt,
                wallTime: completedAt.timeIntervalSince(startedAt),
                approximateCPUTime: max(Self.currentProcessCPUTime() - startingCPUTime, 0),
                paths: Self.uint64(paths),
                records: Self.uint64(records),
                visited: Self.uint64(visited),
                yieldedSlices: Self.uint64(yieldedSlices),
                deferredPaths: Self.uint64(deferredPaths),
                largeOverlays: Self.uint64(largeOverlays),
                optimizationDeferrals: Self.uint64(optimizationDeferrals),
                exclusionDecisions: Self.uint64(exclusionInstrumentation.compiledExclusionDecisionCount),
                exclusionRegexMatches: Self.uint64(exclusionInstrumentation.regexMatchCount),
                exclusionFastPathDecisions: Self.uint64(exclusionInstrumentation.fastPathDecisionCount),
                exclusionFastPrunes: Self.uint64(exclusionInstrumentation.fastPruneDirectoryCount)
            )
        }

        private static func uint64(_ value: Int) -> UInt64 {
            UInt64(max(value, 0))
        }

        private static func currentProcessCPUTime() -> TimeInterval {
            var usage = rusage()
            guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
            return timeInterval(usage.ru_utime) + timeInterval(usage.ru_stime)
        }

        private static func timeInterval(_ value: timeval) -> TimeInterval {
            TimeInterval(value.tv_sec) + TimeInterval(value.tv_usec) / 1_000_000
        }
    }

    private final class ExclusionInstrumentationAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var value = FileExclusionQuery.Instrumentation()

        func add(_ instrumentation: FileExclusionQuery.Instrumentation) {
            lock.withLock {
                value.add(instrumentation)
            }
        }

        func snapshot() -> FileExclusionQuery.Instrumentation {
            lock.withLock { value }
        }
    }

    private struct ScanProgress {
        let store: HeapPagedRecordStore
        let visited: Int
    }

    private struct ScanCheckpointProgress {
        let store: HeapPagedRecordStore
        let visited: Int
        let pendingDirectories: [String]
        let activeDirectories: [String]
        let completedDirectories: [String]
        let operationStartedAt: Date
    }

    private struct FileSystemRecordCandidate {
        let url: URL
        let path: String
        let isDirectory: Bool
        let isSymlink: Bool
        let record: FileRecord
    }

    private enum FileSystemRecordLookup {
        case record(FileSystemRecordCandidate)
        case missing
        case retry(error: Int32)
    }

    private enum ShallowDirectoryEnumerationResult {
        case completed
        case stopped
        case retry(error: Int32)
    }

    private final class ScanVolumeNameCache: @unchecked Sendable {
        private var volumeNamesByDevice: [dev_t: String] = [:]

        func volumeName(for url: URL, statBlock: stat) -> String {
            if let cached = volumeNamesByDevice[statBlock.st_dev] {
                return cached
            }

            let volumeName = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? ""
            volumeNamesByDevice[statBlock.st_dev] = volumeName
            return volumeName
        }
    }

    private final class ConcurrentScanState: @unchecked Sendable {
        private let condition = NSCondition()
        private let onTerminalState: @Sendable () -> Void
        private var pendingDirectories: [URL] = []
        private var knownDirectoryPaths: Set<String>
        private var activeDirectories: Set<String> = []
        private var completedDirectories: Set<String>
        private let tracksCompletedDirectories: Bool
        private var shouldStop = false
        private var records: [String: FileRecord]?
        private let builder: HeapPagedRecordStore.Builder?
        private let reconciliationAccumulator: ReconciliationScanAccumulator?
        private var visited = 0
        private var yieldedSlices = 0
        private var lastStatusPublishedCount = 0
        private var lastStatusPublishedAt = Date.distantPast
        private var lastPublishedCount = 0
        private var lastPublishedAt = Date.distantPast
        private var checkpointSchedule: ScanCheckpointSchedule
        private let operationStartedAt: Date
        private var frontierMetrics = ScanFrontierMetrics()

        init(
            reservedCapacity: Int,
            roots: [String] = [],
            existingRecords: [FileRecord] = [],
            pendingDirectories: [URL] = [],
            completedDirectories: Set<String> = [],
            operationStartedAt: Date,
            lastCheckpointCount: Int = 0,
            lastCheckpointAt: Date? = nil,
            buildsRecordStore: Bool = true,
            reconciliationBaselineStore: RecordStore? = nil,
            tracksCompletedDirectories: Bool = true,
            onTerminalState: @escaping @Sendable () -> Void = {}
        ) {
            precondition(
                !buildsRecordStore || reconciliationBaselineStore == nil,
                "A scan cannot build a record store and a reconciliation delta at the same time."
            )
            self.completedDirectories = completedDirectories
            self.tracksCompletedDirectories = tracksCompletedDirectories
            self.onTerminalState = onTerminalState
            knownDirectoryPaths = completedDirectories
            self.operationStartedAt = operationStartedAt
            checkpointSchedule = ScanCheckpointSchedule(
                operationStartedAt: operationStartedAt,
                lastCheckpointCount: lastCheckpointCount,
                lastCheckpointAt: lastCheckpointAt
            )
            builder = buildsRecordStore ? HeapPagedRecordStore.Builder(reservedCapacity: reservedCapacity, roots: roots) : nil
            reconciliationAccumulator = reconciliationBaselineStore.map {
                ReconciliationScanAccumulator(baselineStore: $0)
            }
            if buildsRecordStore || reconciliationBaselineStore != nil {
                records = nil
            } else {
                var recordsByPath: [String: FileRecord] = [:]
                recordsByPath.reserveCapacity(max(reservedCapacity, existingRecords.count))
                records = recordsByPath
            }
            for record in existingRecords {
                appendRecordWithoutLock(record)
            }
            for directory in pendingDirectories
                where knownDirectoryPaths.insert(directory.path).inserted {
                self.pendingDirectories.append(directory)
            }
            frontierMetrics.maxPendingDirectoryCount = self.pendingDirectories.count
        }

        func enqueue(_ directory: URL) {
            enqueue(contentsOf: [directory])
        }

        func enqueue(contentsOf directories: [URL]) {
            guard !directories.isEmpty else { return }

            condition.lock()
            frontierMetrics.enqueueCallCount += 1
            var enqueuedCount = 0
            for directory in directories where knownDirectoryPaths.insert(directory.path).inserted {
                pendingDirectories.append(directory)
                enqueuedCount += 1
            }
            frontierMetrics.enqueuedDirectoryCount += UInt64(enqueuedCount)
            frontierMetrics.maxPendingDirectoryCount = max(
                frontierMetrics.maxPendingDirectoryCount,
                pendingDirectories.count
            )
            if enqueuedCount > 1 {
                condition.broadcast()
            } else if enqueuedCount == 1 {
                condition.signal()
            }
            condition.unlock()
        }

        func addInitialRecord(_ record: FileRecord) {
            condition.lock()
            appendRecordWithoutLock(record)
            condition.unlock()
        }

        func markStopped() {
            condition.lock()
            let newlyStopped = !shouldStop
            shouldStop = true
            condition.broadcast()
            condition.unlock()
            if newlyStopped {
                onTerminalState()
            }
        }

        func isStoppedOrComplete() -> Bool {
            condition.lock()
            defer { condition.unlock() }
            return shouldStop || (pendingDirectories.isEmpty && activeDirectories.isEmpty)
        }

        func isComplete() -> Bool {
            condition.lock()
            defer { condition.unlock() }
            return pendingDirectories.isEmpty && activeDirectories.isEmpty
        }

        func nextDirectory() -> URL? {
            nextDirectories(maxCount: 1).first
        }

        func nextDirectories(maxCount requestedMaxCount: Int) -> [URL] {
            condition.lock()
            defer { condition.unlock() }
            frontierMetrics.claimCallCount += 1

            while pendingDirectories.isEmpty, !activeDirectories.isEmpty, !shouldStop {
                condition.wait()
            }

            guard !shouldStop, !(pendingDirectories.isEmpty && activeDirectories.isEmpty) else {
                return []
            }

            let count = min(max(requestedMaxCount, 1), pendingDirectories.count)
            var directories: [URL] = []
            directories.reserveCapacity(count)
            for _ in 0..<count {
                let directory = pendingDirectories.removeLast()
                activeDirectories.insert(directory.path)
                directories.append(directory)
            }
            frontierMetrics.claimedDirectoryCount += UInt64(directories.count)
            frontierMetrics.maxActiveDirectoryCount = max(
                frontierMetrics.maxActiveDirectoryCount,
                activeDirectories.count
            )
            return directories
        }

        func finishDirectory(_ directory: URL) {
            finishDirectories([directory])
        }

        func finishDirectories(_ directories: [URL]) {
            guard !directories.isEmpty else { return }

            condition.lock()
            frontierMetrics.finishCallCount += 1
            for directory in directories {
                activeDirectories.remove(directory.path)
                if tracksCompletedDirectories {
                    completedDirectories.insert(directory.path)
                }
            }
            frontierMetrics.finishedDirectoryCount += UInt64(directories.count)
            let reachedTerminalState = shouldStop || (pendingDirectories.isEmpty && activeDirectories.isEmpty)
            if reachedTerminalState {
                condition.broadcast()
            } else {
                condition.signal()
            }
            condition.unlock()
            if reachedTerminalState {
                onTerminalState()
            }
        }

        func append(_ batch: [FileRecord]) {
            guard !batch.isEmpty else { return }

            condition.lock()
            frontierMetrics.appendCallCount += 1
            frontierMetrics.appendedRecordCount += UInt64(batch.count)
            for record in batch {
                appendRecordWithoutLock(record)
            }
            condition.unlock()
        }

        func recordYieldedSlice() {
            condition.lock()
            yieldedSlices += 1
            condition.unlock()
        }

        private func appendRecordWithoutLock(_ record: FileRecord) {
            if let builder {
                let previousCount = builder.count
                builder.append(record)
                if builder.count > previousCount {
                    visited += 1
                }
                return
            }
            if let reconciliationAccumulator {
                if reconciliationAccumulator.append(record) {
                    visited += 1
                }
                return
            }

            let isNew = records?[record.path] == nil
            records?[record.path] = record
            if isNew {
                visited += 1
            }
        }

        func statusIfNeeded(force: Bool) -> Int? {
            condition.lock()
            defer { condition.unlock() }

            guard force || visited != lastStatusPublishedCount else {
                return nil
            }

            let now = Date()
            let shouldPublish = force
                || visited - lastStatusPublishedCount >= FileIndex.scanStatusPublishRecordInterval
                || now.timeIntervalSince(lastStatusPublishedAt) >= FileIndex.scanStatusPublishTimeInterval
            guard shouldPublish else { return nil }

            lastStatusPublishedCount = visited
            lastStatusPublishedAt = now
            return visited
        }

        func publishSnapshotIfNeeded(force: Bool) -> ScanProgress? {
            guard let builder else { return nil }
            condition.lock()
            defer { condition.unlock() }

            let now = Date()
            let recordCount = builder.count
            let shouldPublish = force
                || recordCount - lastPublishedCount >= FileIndex.primaryPublishRecordInterval
                || now.timeIntervalSince(lastPublishedAt) >= FileIndex.primaryPublishTimeInterval
            guard shouldPublish else { return nil }

            lastPublishedCount = recordCount
            lastPublishedAt = now
            let store = builder.snapshot(includesPathIndex: false)
            frontierMetrics.searchableSnapshotCount += 1
            frontierMetrics.searchableSnapshotRowCount += UInt64(store.count)
            return ScanProgress(store: store, visited: visited)
        }

        func checkpointIfNeeded(force: Bool) -> ScanCheckpointProgress? {
            guard let builder else { return nil }
            condition.lock()
            defer { condition.unlock() }

            let now = Date()
            guard checkpointSchedule.shouldCreateCheckpoint(recordCount: builder.count, at: now, force: force) else {
                return nil
            }
            let store = builder.snapshot(includesPathIndex: false)
            frontierMetrics.checkpointSnapshotCount += 1
            frontierMetrics.checkpointSnapshotRowCount += UInt64(store.count)
            return ScanCheckpointProgress(
                store: store,
                visited: visited,
                pendingDirectories: pendingDirectories.map(\.path),
                activeDirectories: activeDirectories.sorted(),
                completedDirectories: completedDirectories.sorted(),
                operationStartedAt: operationStartedAt
            )
        }

        func result(exclusionInstrumentation: FileExclusionQuery.Instrumentation) -> (ScanResult, Bool) {
            condition.lock()
            defer { condition.unlock() }
            let store = builder?.snapshot(includesPathIndex: true)
            let reconciliationDelta = reconciliationAccumulator?.result()
            frontierMetrics.retainedRecordDictionaryCount = records?.count
                ?? reconciliationDelta?.upserts.count
                ?? 0
            if let store {
                frontierMetrics.finalSnapshotCount += 1
                frontierMetrics.finalSnapshotRowCount += UInt64(store.count)
            }
            return (
                ScanResult(
                    records: records ?? [:],
                    store: store,
                    reconciliationDelta: reconciliationDelta,
                    recordCount: store?.count
                        ?? reconciliationDelta?.recordCount
                        ?? records?.count
                        ?? 0,
                    visited: visited,
                    yieldedSlices: yieldedSlices,
                    frontierMetrics: frontierMetrics,
                    exclusionInstrumentation: exclusionInstrumentation
                ),
                shouldStop
            )
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
        private let sortOrderLock = NSLock()
        private var sortOrdersAscending: [SortColumn: [Int]]
        private var visibleSortOrdersAscending: [SortColumn: [Int]]
        private var sortRankCache: [SortRankCacheKey: [Int32]] = [:]
        private var sortRankCacheOrder: [SortRankCacheKey] = []
        let gramIndex: MappedIntPostingIndex?
        let pathGramShards: [PathGramShard]
        let pathGramExpectedRowCount: Int
        let nameGramIndex: MappedIntPostingIndex?
        let componentGramIndex: ComponentGramPostingIndex?
        let resultPrefixCounts: [Int]
        let visibleResultPrefixCounts: [Int]
        let extensionIndex: [String: [Int32]]
        private let childLinks: ChildLinks?
        let visibleCount: Int?
        let hasSortedOrder: Bool
        let prefersDegradedSearch: Bool
        let diagnostics: SearchStructureDiagnostics

        private struct ChildLinks {
            let firstChild: [Int32]
            let nextSibling: [Int32]
            let roots: [Int32]
        }

        private struct SortRankCacheKey: Hashable {
            let column: SortColumn
            let ascending: Bool
            let includeHidden: Bool
        }

        struct PathGramShard: Sendable {
            let snapshotRevision: UInt64
            let schemaVersion: Int
            let rowCount: Int
            let range: Range<Int>
            let completedAt: Date
            let index: MappedIntPostingIndex?

            var coveredCount: Int {
                max(0, range.upperBound - range.lowerBound)
            }
        }

        var count: Int { store.count }
        var resultCount: Int { store.storedResultCount ?? (0..<store.count).filter { store.isResultRow(at: $0) }.count }
        var hasModifiedSortOrder: Bool {
            resultCount == 0 || modifiedDescending.count == resultCount
        }
        var visibleResultCount: Int? {
            if let visibleCount {
                return visibleCount
            }
            if let count = visibleResultPrefixCounts.last {
                return count
            }
            if hasSortedOrder {
                return visibleModifiedDescending.count
            }
            return store.storedVisibleCount
        }
        var virtualRowCount: Int { count - resultCount }
        var records: [FileRecord] { store.allRecords() }
        var isOptimizedForSearch: Bool {
            resultCount == 0 || (hasSortedOrder && nameGramIndex != nil && componentGramIndex != nil)
        }

        init(
            records: [FileRecord],
            roots: [String] = [],
            buildsSearchStructures: Bool = true,
            buildsPathGramIndex: Bool = true,
            optimizedSortColumns: Set<SortColumn> = Set(SortColumn.optimizedIndexColumns),
            prefersDegradedSearch: Bool = false
        ) {
            self.store = HeapPagedRecordStore(records: records, roots: roots)
            self.prefersDegradedSearch = prefersDegradedSearch
            if buildsSearchStructures {
                let buildsPathGramIndex = buildsPathGramIndex && FileIndex.shouldBuildPathGramIndex(records: records)
                self.gramIndex = buildsPathGramIndex ? Self.makePathGramIndex(store: store) : nil
                self.pathGramShards = []
                self.pathGramExpectedRowCount = buildsPathGramIndex ? store.count : 0
                let gramIndexes = Self.makeNameAndComponentGramIndexes(store: store)
                self.nameGramIndex = gramIndexes.name
                self.componentGramIndex = gramIndexes.component
                self.resultPrefixCounts = Self.makeResultPrefixCounts(store: store, visibleOnly: false)
                self.visibleResultPrefixCounts = Self.makeResultPrefixCounts(store: store, visibleOnly: true)
                let extensionData = Self.makeExtensionIndexAndVisibleCount(store: store)
                self.extensionIndex = extensionData.extensionIndex
                self.childLinks = Self.makeChildLinks(store: store)
                self.visibleCount = extensionData.visibleCount
                let sortedByModified = Self.makeModifiedDescending(store: store)
                self.modifiedDescending = sortedByModified
                let sortedByModifiedAscending = Array(sortedByModified.reversed())
                self.modifiedAscending = sortedByModifiedAscending
                let sortedByName = Self.makeNameAscending(store: store)
                self.nameAscending = sortedByName
                self.nameDescending = Array(sortedByName.reversed())
                let visibleSortedByModified = Self.makeVisibleModifiedDescending(
                    modifiedDescending: sortedByModified,
                    store: store
                )
                self.visibleModifiedDescending = visibleSortedByModified
                self.visibleModifiedAscending = Array(visibleSortedByModified.reversed())
                self.sortOrdersAscending = Self.makeAdditionalSortOrdersAscending(
                    store: store,
                    optimizedSortColumns: optimizedSortColumns,
                    persistedOrders: [:]
                )
                self.visibleSortOrdersAscending = [:]
                self.hasSortedOrder = true
                self.diagnostics = Self.makeDiagnostics(
                    pathGramIndexEnabled: gramIndex != nil,
                    gramIndex: gramIndex,
                    pathGramShards: pathGramShards,
                    pathGramExpectedRowCount: pathGramExpectedRowCount,
                    nameGramIndex: nameGramIndex,
                    componentGramIndex: componentGramIndex,
                    extensionIndex: extensionIndex
                )
            } else {
                self.gramIndex = nil
                self.pathGramShards = []
                self.pathGramExpectedRowCount = 0
                self.nameGramIndex = nil
                self.componentGramIndex = nil
                self.resultPrefixCounts = []
                self.visibleResultPrefixCounts = []
                self.extensionIndex = [:]
                self.childLinks = nil
                self.visibleCount = nil
                self.modifiedDescending = []
                self.modifiedAscending = []
                self.nameAscending = []
                self.nameDescending = []
                self.visibleModifiedDescending = []
                self.visibleModifiedAscending = []
                self.sortOrdersAscending = [:]
                self.visibleSortOrdersAscending = [:]
                self.hasSortedOrder = false
                self.diagnostics = Self.makeDiagnostics(
                    pathGramIndexEnabled: false,
                    gramIndex: gramIndex,
                    pathGramShards: pathGramShards,
                    pathGramExpectedRowCount: pathGramExpectedRowCount,
                    nameGramIndex: nameGramIndex,
                    componentGramIndex: componentGramIndex,
                    extensionIndex: extensionIndex
                )
            }
        }

        init(
            store: RecordStore,
            buildsSearchStructures: Bool = true,
            buildsPathGramIndex: Bool = true,
            optimizedSortColumns: Set<SortColumn> = Set(SortColumn.optimizedIndexColumns),
            buildsAdditionalSortOrders: Bool = true,
            prefersDegradedSearch: Bool = false
        ) {
            self.store = store
            self.prefersDegradedSearch = prefersDegradedSearch
            if buildsSearchStructures {
                let buildsPathGramIndex = buildsPathGramIndex && FileIndex.shouldBuildPathGramIndex(store: store)
                self.gramIndex = buildsPathGramIndex ? Self.makePathGramIndex(store: store) : nil
                self.pathGramShards = []
                self.pathGramExpectedRowCount = buildsPathGramIndex ? store.count : 0
                let gramIndexes = Self.makeNameAndComponentGramIndexes(store: store)
                self.nameGramIndex = gramIndexes.name
                self.componentGramIndex = gramIndexes.component
                self.resultPrefixCounts = Self.makeResultPrefixCounts(store: store, visibleOnly: false)
                self.visibleResultPrefixCounts = Self.makeResultPrefixCounts(store: store, visibleOnly: true)
                let extensionData = Self.makeExtensionIndexAndVisibleCount(store: store)
                self.extensionIndex = extensionData.extensionIndex
                self.childLinks = Self.makeChildLinks(store: store)
                self.visibleCount = extensionData.visibleCount
                let sortedByModified = Self.makeModifiedDescending(store: store)
                self.modifiedDescending = sortedByModified
                let sortedByModifiedAscending = Array(sortedByModified.reversed())
                self.modifiedAscending = sortedByModifiedAscending
                let sortedByName = Self.makeNameAscending(store: store)
                self.nameAscending = sortedByName
                self.nameDescending = Array(sortedByName.reversed())
                let visibleSortedByModified = Self.makeVisibleModifiedDescending(
                    modifiedDescending: sortedByModified,
                    store: store
                )
                self.visibleModifiedDescending = visibleSortedByModified
                self.visibleModifiedAscending = Array(visibleSortedByModified.reversed())
                self.sortOrdersAscending = Self.makeAdditionalSortOrdersAscending(
                    store: store,
                    optimizedSortColumns: optimizedSortColumns,
                    persistedOrders: [:],
                    buildsMissingOrders: buildsAdditionalSortOrders
                )
                self.visibleSortOrdersAscending = [:]
                self.hasSortedOrder = true
                self.diagnostics = Self.makeDiagnostics(
                    pathGramIndexEnabled: gramIndex != nil,
                    gramIndex: gramIndex,
                    pathGramShards: pathGramShards,
                    pathGramExpectedRowCount: pathGramExpectedRowCount,
                    nameGramIndex: nameGramIndex,
                    componentGramIndex: componentGramIndex,
                    extensionIndex: extensionIndex
                )
            } else {
                self.gramIndex = nil
                self.pathGramShards = []
                self.pathGramExpectedRowCount = 0
                self.nameGramIndex = nil
                self.componentGramIndex = nil
                self.resultPrefixCounts = []
                self.visibleResultPrefixCounts = []
                self.extensionIndex = [:]
                self.childLinks = nil
                self.visibleCount = nil
                self.modifiedDescending = []
                self.modifiedAscending = []
                self.nameAscending = []
                self.nameDescending = []
                self.visibleModifiedDescending = []
                self.visibleModifiedAscending = []
                self.sortOrdersAscending = [:]
                self.visibleSortOrdersAscending = [:]
                self.hasSortedOrder = false
                self.diagnostics = Self.makeDiagnostics(
                    pathGramIndexEnabled: false,
                    gramIndex: gramIndex,
                    pathGramShards: pathGramShards,
                    pathGramExpectedRowCount: pathGramExpectedRowCount,
                    nameGramIndex: nameGramIndex,
                    componentGramIndex: componentGramIndex,
                    extensionIndex: extensionIndex
                )
            }
        }

        init(
            store: RecordStore,
            persistedStructures: PersistedSearchStructures,
            optimizedSortColumns: Set<SortColumn> = Set(SortColumn.optimizedIndexColumns)
        ) {
            self.store = store
            self.prefersDegradedSearch = false
            self.gramIndex = persistedStructures.pathGramIndex
            self.pathGramShards = []
            self.pathGramExpectedRowCount = persistedStructures.pathGramIndex == nil ? 0 : store.count
            self.nameGramIndex = persistedStructures.nameGramIndex
            self.componentGramIndex = persistedStructures.componentGramIndex
            self.resultPrefixCounts = Self.makeResultPrefixCounts(store: store, visibleOnly: false)
            self.visibleResultPrefixCounts = Self.makeResultPrefixCounts(store: store, visibleOnly: true)
            let extensionData = Self.makeExtensionIndexAndVisibleCount(store: store)
            self.extensionIndex = extensionData.extensionIndex
            self.childLinks = Self.makeChildLinks(store: store)
            self.visibleCount = extensionData.visibleCount

            let expectedModifiedCount = store.storedResultCount ?? store.count
            if let modifiedDescending = persistedStructures.modifiedDescending, modifiedDescending.count == expectedModifiedCount {
                self.modifiedDescending = modifiedDescending
                let modifiedAscending = Array(modifiedDescending.reversed())
                self.modifiedAscending = modifiedAscending
                let visibleModifiedDescending = persistedStructures.visibleModifiedDescending
                    ?? Self.makeVisibleModifiedDescending(modifiedDescending: modifiedDescending, store: store)
                self.visibleModifiedDescending = visibleModifiedDescending
                self.visibleModifiedAscending = Array(visibleModifiedDescending.reversed())
                if nameGramIndex != nil, componentGramIndex != nil {
                    let persistedNameOrder = optimizedSortColumns.contains(.name)
                        ? persistedStructures.sortOrdersAscending[.name]
                        : nil
                    let sortedByName: [Int]
                    if let persistedNameOrder, persistedNameOrder.count == expectedModifiedCount {
                        sortedByName = persistedNameOrder
                    } else {
                        sortedByName = Self.makeNameAscending(store: store)
                    }
                    self.nameAscending = sortedByName
                    self.nameDescending = Array(sortedByName.reversed())
                    self.sortOrdersAscending = Self.makeAdditionalSortOrdersAscending(
                        store: store,
                        optimizedSortColumns: optimizedSortColumns,
                        persistedOrders: persistedStructures.sortOrdersAscending,
                        buildsMissingOrders: false
                    )
                    self.visibleSortOrdersAscending = [:]
                    self.hasSortedOrder = true
                } else {
                    self.nameAscending = []
                    self.nameDescending = []
                    self.sortOrdersAscending = [:]
                    self.visibleSortOrdersAscending = [:]
                    self.hasSortedOrder = false
                }
            } else {
                self.modifiedDescending = []
                self.modifiedAscending = []
                self.nameAscending = []
                self.nameDescending = []
                self.visibleModifiedDescending = []
                self.visibleModifiedAscending = []
                self.sortOrdersAscending = [:]
                self.visibleSortOrdersAscending = [:]
                self.hasSortedOrder = false
            }

            self.diagnostics = Self.makeDiagnostics(
                pathGramIndexEnabled: gramIndex != nil,
                gramIndex: gramIndex,
                pathGramShards: pathGramShards,
                pathGramExpectedRowCount: pathGramExpectedRowCount,
                nameGramIndex: nameGramIndex,
                componentGramIndex: componentGramIndex,
                extensionIndex: extensionIndex
            )
        }

        private init(
            store: RecordStore,
            modifiedDescending: [Int],
            gramIndex: MappedIntPostingIndex?,
            pathGramShards: [PathGramShard] = [],
            pathGramExpectedRowCount: Int = 0,
            nameGramIndex: MappedIntPostingIndex?,
            componentGramIndex: ComponentGramPostingIndex?,
            extensionIndex: [String: [Int32]],
            childLinks: ChildLinks? = nil,
            nameAscending: [Int]? = nil,
            nameDescending: [Int]? = nil,
            sortOrdersAscending: [SortColumn: [Int]] = [:],
            visibleCount: Int?,
            hasSortedOrder: Bool,
            prefersDegradedSearch: Bool = false
        ) {
            self.store = store
            self.prefersDegradedSearch = prefersDegradedSearch
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
            self.sortOrdersAscending = hasSortedOrder ? sortOrdersAscending : [:]
            self.visibleSortOrdersAscending = [:]
            self.gramIndex = gramIndex
            self.pathGramShards = gramIndex == nil ? pathGramShards : []
            self.pathGramExpectedRowCount = gramIndex == nil ? pathGramExpectedRowCount : store.count
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
                pathGramShards: self.pathGramShards,
                pathGramExpectedRowCount: self.pathGramExpectedRowCount,
                nameGramIndex: nameGramIndex,
                componentGramIndex: componentGramIndex,
                extensionIndex: extensionIndex
            )
        }

        private init(
            reusingCore source: SearchSnapshot,
            gramIndex: MappedIntPostingIndex?,
            pathGramShards: [PathGramShard],
            pathGramExpectedRowCount: Int
        ) {
            let sortState = source.sortOrderLock.withLock {
                (
                    orders: source.sortOrdersAscending,
                    visibleOrders: source.visibleSortOrdersAscending,
                    rankCache: source.sortRankCache,
                    rankCacheOrder: source.sortRankCacheOrder
                )
            }
            store = source.store
            modifiedDescending = source.modifiedDescending
            modifiedAscending = source.modifiedAscending
            nameAscending = source.nameAscending
            nameDescending = source.nameDescending
            visibleModifiedDescending = source.visibleModifiedDescending
            visibleModifiedAscending = source.visibleModifiedAscending
            sortOrdersAscending = sortState.orders
            visibleSortOrdersAscending = sortState.visibleOrders
            sortRankCache = sortState.rankCache
            sortRankCacheOrder = sortState.rankCacheOrder
            self.gramIndex = gramIndex
            self.pathGramShards = gramIndex == nil ? pathGramShards : []
            self.pathGramExpectedRowCount = gramIndex == nil ? pathGramExpectedRowCount : source.store.count
            nameGramIndex = source.nameGramIndex
            componentGramIndex = source.componentGramIndex
            resultPrefixCounts = source.resultPrefixCounts
            visibleResultPrefixCounts = source.visibleResultPrefixCounts
            extensionIndex = source.extensionIndex
            childLinks = source.childLinks
            visibleCount = source.visibleCount
            hasSortedOrder = source.hasSortedOrder
            prefersDegradedSearch = source.prefersDegradedSearch
            diagnostics = Self.makeDiagnostics(
                pathGramIndexEnabled: gramIndex != nil,
                gramIndex: gramIndex,
                pathGramShards: self.pathGramShards,
                pathGramExpectedRowCount: self.pathGramExpectedRowCount,
                nameGramIndex: nameGramIndex,
                componentGramIndex: componentGramIndex,
                extensionIndex: extensionIndex
            )
        }

        private init(reusingCore source: SearchSnapshot, store: RecordStore) {
            let sortState = source.sortOrderLock.withLock {
                (
                    orders: source.sortOrdersAscending,
                    visibleOrders: source.visibleSortOrdersAscending,
                    rankCache: source.sortRankCache,
                    rankCacheOrder: source.sortRankCacheOrder
                )
            }
            self.store = store
            modifiedDescending = source.modifiedDescending
            modifiedAscending = source.modifiedAscending
            nameAscending = source.nameAscending
            nameDescending = source.nameDescending
            visibleModifiedDescending = source.visibleModifiedDescending
            visibleModifiedAscending = source.visibleModifiedAscending
            sortOrdersAscending = sortState.orders
            visibleSortOrdersAscending = sortState.visibleOrders
            sortRankCache = sortState.rankCache
            sortRankCacheOrder = sortState.rankCacheOrder
            gramIndex = source.gramIndex
            pathGramShards = source.pathGramShards
            pathGramExpectedRowCount = source.pathGramExpectedRowCount
            nameGramIndex = source.nameGramIndex
            componentGramIndex = source.componentGramIndex
            resultPrefixCounts = source.resultPrefixCounts
            visibleResultPrefixCounts = source.visibleResultPrefixCounts
            extensionIndex = source.extensionIndex
            childLinks = source.childLinks
            visibleCount = source.visibleCount
            hasSortedOrder = source.hasSortedOrder
            prefersDegradedSearch = source.prefersDegradedSearch
            diagnostics = source.diagnostics
        }

        func maskingRows(_ rows: PackedRowBitSet) -> SearchSnapshot {
            guard rows.setBitCount > 0 else { return self }
            return SearchSnapshot(
                reusingCore: self,
                store: RowMaskingRecordStore(base: store, maskedRows: rows)
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
            let updatedSortOrders = Self.updatedAdditionalSortOrdersAscending(
                existing: sortOrderLock.withLock { sortOrdersAscending },
                changedIndices: changedIndices,
                changed: changed,
                store: updatedStore
            )

            return SearchSnapshot(
                store: updatedStore,
                modifiedDescending: mergedDescending,
                gramIndex: gramIndex,
                pathGramShards: [],
                pathGramExpectedRowCount: gramIndex == nil ? 0 : updatedStore.count,
                nameGramIndex: nameGramIndex,
                componentGramIndex: componentGramIndex,
                extensionIndex: extensionIndex,
                childLinks: childLinks,
                nameAscending: nameAscending,
                nameDescending: nameDescending,
                sortOrdersAscending: updatedSortOrders,
                visibleCount: Self.makeVisibleCount(store: updatedStore),
                hasSortedOrder: true,
                prefersDegradedSearch: prefersDegradedSearch
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

        private func currentAdditionalSortOrdersAscending() -> [SortColumn: [Int]] {
            sortOrderLock.withLock { sortOrdersAscending }
        }

        func rebasedForMappedPersistence(
            store mappedStore: RecordStore,
            completePathGramIndex: MappedIntPostingIndex?,
            optimizedSortColumns: Set<SortColumn>
        ) -> SearchSnapshot {
            let expectedResultCount = mappedStore.storedResultCount ?? mappedStore.count
            let expectedSourceResultCount = store.storedResultCount ?? store.count
            let canReuseRowOrderedStructures = store.kind == .mapped
                && store.count == mappedStore.count
                && expectedSourceResultCount == expectedResultCount
            let existingAdditionalOrders = currentAdditionalSortOrdersAscending()
            guard canReuseRowOrderedStructures else {
                let existingAdditionalColumns = Set(existingAdditionalOrders.compactMap { entry in
                    Self.usesAdditionalSortOrder(entry.key) && entry.value.count == expectedSourceResultCount
                        ? entry.key
                        : nil
                })
                return SearchSnapshot(
                    store: mappedStore,
                    buildsSearchStructures: true,
                    buildsPathGramIndex: false,
                    optimizedSortColumns: optimizedSortColumns.intersection(existingAdditionalColumns),
                    prefersDegradedSearch: prefersDegradedSearch
                )
            }

            let extensionData = extensionIndex.isEmpty || visibleCount == nil
                ? Self.makeExtensionIndexAndVisibleCount(store: mappedStore)
                : nil
            var validAdditionalOrders: [SortColumn: [Int]] = [:]
            for (column, order) in existingAdditionalOrders
                where Self.usesAdditionalSortOrder(column) && order.count == expectedResultCount
            {
                validAdditionalOrders[column] = order
            }
            let persistedModifiedDescending = hasModifiedSortOrder && modifiedDescending.count == expectedResultCount
                ? modifiedDescending
                : Self.makeModifiedDescending(store: mappedStore)
            let persistedNameAscending = nameAscending.count == expectedResultCount
                ? nameAscending
                : nil
            let persistedNameDescending = nameDescending.count == expectedResultCount
                ? nameDescending
                : nil
            let rebuiltGramIndexes = nameGramIndex == nil || componentGramIndex == nil
                ? Self.makeNameAndComponentGramIndexes(store: mappedStore)
                : nil

            return SearchSnapshot(
                store: mappedStore,
                modifiedDescending: persistedModifiedDescending,
                gramIndex: completePathGramIndex,
                pathGramShards: [],
                pathGramExpectedRowCount: completePathGramIndex == nil ? 0 : mappedStore.count,
                nameGramIndex: rebuiltGramIndexes?.name ?? nameGramIndex,
                componentGramIndex: rebuiltGramIndexes?.component ?? componentGramIndex,
                extensionIndex: extensionData?.extensionIndex ?? extensionIndex,
                childLinks: canReuseRowOrderedStructures ? childLinks : nil,
                nameAscending: persistedNameAscending,
                nameDescending: persistedNameDescending,
                sortOrdersAscending: validAdditionalOrders,
                visibleCount: extensionData?.visibleCount ?? visibleCount,
                hasSortedOrder: true,
                prefersDegradedSearch: prefersDegradedSearch
            )
        }

        func addingNameGramIndex() -> SearchSnapshot {
            guard nameGramIndex == nil || componentGramIndex == nil else { return self }
            let rebuiltGramIndexes = Self.makeNameAndComponentGramIndexes(store: store)
            return SearchSnapshot(
                store: store,
                modifiedDescending: modifiedDescending,
                gramIndex: gramIndex,
                pathGramShards: pathGramShards,
                pathGramExpectedRowCount: pathGramExpectedRowCount,
                nameGramIndex: rebuiltGramIndexes.name,
                componentGramIndex: rebuiltGramIndexes.component,
                extensionIndex: extensionIndex,
                childLinks: childLinks,
                nameAscending: nameAscending,
                nameDescending: nameDescending,
                sortOrdersAscending: currentAdditionalSortOrdersAscending(),
                visibleCount: visibleCount,
                hasSortedOrder: hasSortedOrder,
                prefersDegradedSearch: prefersDegradedSearch
            )
        }

        func addingExtensionIndex() -> SearchSnapshot {
            guard extensionIndex.isEmpty || visibleCount == nil else { return self }
            let extensionData = Self.makeExtensionIndexAndVisibleCount(store: store)
            return SearchSnapshot(
                store: store,
                modifiedDescending: modifiedDescending,
                gramIndex: gramIndex,
                pathGramShards: pathGramShards,
                pathGramExpectedRowCount: pathGramExpectedRowCount,
                nameGramIndex: nameGramIndex,
                componentGramIndex: componentGramIndex,
                extensionIndex: extensionIndex.isEmpty ? extensionData.extensionIndex : extensionIndex,
                childLinks: childLinks,
                nameAscending: nameAscending,
                nameDescending: nameDescending,
                sortOrdersAscending: currentAdditionalSortOrdersAscending(),
                visibleCount: visibleCount ?? extensionData.visibleCount,
                hasSortedOrder: hasSortedOrder,
                prefersDegradedSearch: prefersDegradedSearch
            )
        }

        func addingModifiedSortOrder() -> SearchSnapshot {
            guard !hasSortedOrder else { return self }
            return SearchSnapshot(
                store: store,
                modifiedDescending: Self.makeModifiedDescending(store: store),
                gramIndex: gramIndex,
                pathGramShards: pathGramShards,
                pathGramExpectedRowCount: pathGramExpectedRowCount,
                nameGramIndex: nameGramIndex,
                componentGramIndex: componentGramIndex,
                extensionIndex: extensionIndex,
                childLinks: childLinks,
                nameAscending: nameAscending,
                nameDescending: nameDescending,
                sortOrdersAscending: currentAdditionalSortOrdersAscending(),
                visibleCount: visibleCount,
                hasSortedOrder: true,
                prefersDegradedSearch: prefersDegradedSearch
            )
        }

        func addingModifiedSortOrderOnly() -> SearchSnapshot {
            guard !hasModifiedSortOrder else { return self }
            return SearchSnapshot(
                store: store,
                modifiedDescending: Self.makeModifiedDescending(store: store),
                gramIndex: gramIndex,
                pathGramShards: pathGramShards,
                pathGramExpectedRowCount: pathGramExpectedRowCount,
                nameGramIndex: nameGramIndex,
                componentGramIndex: componentGramIndex,
                extensionIndex: extensionIndex,
                childLinks: childLinks,
                sortOrdersAscending: currentAdditionalSortOrdersAscending(),
                visibleCount: visibleCount,
                hasSortedOrder: hasSortedOrder,
                prefersDegradedSearch: prefersDegradedSearch
            )
        }

        func addingPathGramIndexIfBudgetAllows() -> SearchSnapshot {
            guard gramIndex == nil else { return self }
            guard FileIndex.shouldBuildPathGramIndex(store: store) else {
                return self
            }
            return SearchSnapshot(
                reusingCore: self,
                gramIndex: Self.makePathGramIndex(store: store),
                pathGramShards: [],
                pathGramExpectedRowCount: store.count
            )
        }

        func addingPathGramShard(_ shard: PathGramShard, expectedRowCount: Int) -> SearchSnapshot {
            guard
                gramIndex == nil,
                shard.schemaVersion == store.schemaVersion,
                shard.rowCount == store.count,
                shard.range.lowerBound >= 0,
                shard.range.lowerBound < shard.range.upperBound,
                shard.range.upperBound <= store.count
            else {
                return self
            }

            var shards = pathGramShards.filter {
                $0.schemaVersion == store.schemaVersion
                    && $0.rowCount == store.count
                    && !$0.range.overlaps(shard.range)
            }
            shards.append(shard)
            shards.sort {
                if $0.range.lowerBound != $1.range.lowerBound {
                    return $0.range.lowerBound < $1.range.lowerBound
                }
                return $0.range.upperBound < $1.range.upperBound
            }

            return SearchSnapshot(
                reusingCore: self,
                gramIndex: nil,
                pathGramShards: shards,
                pathGramExpectedRowCount: expectedRowCount
            )
        }

        func addingCompletePathGramIndex(_ pathGramIndex: MappedIntPostingIndex?) -> SearchSnapshot {
            guard let pathGramIndex else { return self }
            return SearchSnapshot(
                reusingCore: self,
                gramIndex: pathGramIndex,
                pathGramShards: [],
                pathGramExpectedRowCount: store.count
            )
        }

        func removingPathGramAcceleration() -> SearchSnapshot {
            guard gramIndex != nil || !pathGramShards.isEmpty || pathGramExpectedRowCount != 0 else { return self }
            return SearchSnapshot(
                reusingCore: self,
                gramIndex: nil,
                pathGramShards: [],
                pathGramExpectedRowCount: 0
            )
        }

        func settingPathGramExpectedRowCount(_ expectedRowCount: Int) -> SearchSnapshot {
            guard gramIndex == nil, pathGramExpectedRowCount != expectedRowCount else { return self }
            return SearchSnapshot(
                reusingCore: self,
                gramIndex: nil,
                pathGramShards: pathGramShards,
                pathGramExpectedRowCount: expectedRowCount
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

        func rootPath(at index: Int) -> String? {
            store.rootPath(at: index)
        }

        func orderedIndices(
            for sort: SortSpec,
            queryIsEmpty: Bool,
            includeHidden: Bool,
            optimizedSortColumns: Set<SortColumn> = Set(SortColumn.optimizedIndexColumns)
        ) -> [Int]? {
            switch sort.column {
            case .modified:
                guard optimizedSortColumns.contains(.modified) else { return nil }
                guard hasModifiedSortOrder else { return nil }
                if includeHidden {
                    return sort.ascending ? modifiedAscending : modifiedDescending
                }
                return sort.ascending ? visibleModifiedAscending : visibleModifiedDescending
            case .name:
                guard optimizedSortColumns.contains(.name) else { return nil }
                guard hasSortedOrder else { return nil }
                let order = sort.ascending ? nameAscending : nameDescending
                return includeHidden ? order : visibleOrder(for: .name, ascendingOrder: nameAscending, ascending: sort.ascending)
            case .relevance where queryIsEmpty:
                guard optimizedSortColumns.contains(.modified) else { return nil }
                guard hasModifiedSortOrder else { return nil }
                return includeHidden ? modifiedDescending : visibleModifiedDescending
            case .path, .created, .size, .fileExtension, .kind, .volume, .root:
                guard optimizedSortColumns.contains(sort.column) else { return nil }
                guard let ascendingOrder = additionalSortOrderAscending(for: sort.column) else { return nil }
                if includeHidden {
                    return sort.ascending ? ascendingOrder : Array(ascendingOrder.reversed())
                }
                return visibleOrder(for: sort.column, ascendingOrder: ascendingOrder, ascending: sort.ascending)
            case .relevance:
                return nil
            }
        }

        func sortRankMap(
            for sort: SortSpec,
            includeHidden: Bool,
            optimizedSortColumns: Set<SortColumn> = Set(SortColumn.optimizedIndexColumns)
        ) -> [Int32]? {
            let key = SortRankCacheKey(
                column: sort.column,
                ascending: sort.ascending,
                includeHidden: includeHidden
            )
            if let cached = sortOrderLock.withLock({ sortRankCache[key] }) {
                return cached
            }

            guard let order = orderedIndices(
                for: sort,
                queryIsEmpty: false,
                includeHidden: includeHidden,
                optimizedSortColumns: optimizedSortColumns
            ) else {
                return nil
            }

            var ranks = Array(repeating: Int32(-1), count: count)
            for (rank, rowID) in order.enumerated() {
                guard rowID >= 0, rowID < ranks.count, rank <= Int(Int32.max) else {
                    continue
                }
                ranks[rowID] = Int32(rank)
            }

            return sortOrderLock.withLock {
                if let cached = sortRankCache[key] {
                    return cached
                }
                sortRankCache[key] = ranks
                sortRankCacheOrder.removeAll { $0 == key }
                sortRankCacheOrder.append(key)
                while sortRankCacheOrder.count > 3 {
                    let evicted = sortRankCacheOrder.removeFirst()
                    sortRankCache[evicted] = nil
                }
                return ranks
            }
        }

        func hasOptimizedSortOrder(
            for column: SortColumn,
            optimizedSortColumns: Set<SortColumn>
        ) -> Bool {
            guard optimizedSortColumns.contains(column) else { return true }
            switch column {
            case .relevance:
                return true
            case .modified:
                return hasModifiedSortOrder
            case .name:
                return hasSortedOrder && nameAscending.count == resultCount
            case .path, .created, .size, .fileExtension, .kind, .volume, .root:
                return additionalSortOrderAscending(for: column)?.count == resultCount
            }
        }

        func persistedSortOrderAscending(for column: SortColumn) -> [Int]? {
            switch column {
            case .relevance:
                return nil
            case .name:
                return nameAscending.count == resultCount ? nameAscending : nil
            case .modified:
                return modifiedAscending.count == resultCount ? modifiedAscending : nil
            case .path, .created, .size, .fileExtension, .kind, .volume, .root:
                return additionalSortOrderAscending(for: column)
            }
        }

        func addingOptimizedSortOrders(_ optimizedSortColumns: Set<SortColumn>) -> SearchSnapshot {
            guard hasSortedOrder else {
                return addingModifiedSortOrder().addingOptimizedSortOrders(optimizedSortColumns)
            }

            var additionalOrders = currentAdditionalSortOrdersAscending()
            var didAddOrder = false
            for column in optimizedSortColumns where Self.usesAdditionalSortOrder(column) {
                if additionalOrders[column]?.count == resultCount {
                    continue
                }
                additionalOrders[column] = Self.makeSortOrderAscending(store: store, column: column)
                didAddOrder = true
            }

            guard didAddOrder else { return self }
            return SearchSnapshot(
                store: store,
                modifiedDescending: modifiedDescending,
                gramIndex: gramIndex,
                pathGramShards: pathGramShards,
                pathGramExpectedRowCount: pathGramExpectedRowCount,
                nameGramIndex: nameGramIndex,
                componentGramIndex: componentGramIndex,
                extensionIndex: extensionIndex,
                childLinks: childLinks,
                nameAscending: nameAscending,
                nameDescending: nameDescending,
                sortOrdersAscending: additionalOrders,
                visibleCount: visibleCount,
                hasSortedOrder: hasSortedOrder,
                prefersDegradedSearch: prefersDegradedSearch
            )
        }

        func addingOptimizedSortOrder(
            for column: SortColumn,
            optimizedSortColumns: Set<SortColumn>
        ) -> SearchSnapshot {
            guard optimizedSortColumns.contains(column), Self.usesAdditionalSortOrder(column) else {
                return self
            }
            guard hasSortedOrder else {
                return addingModifiedSortOrder().addingOptimizedSortOrder(
                    for: column,
                    optimizedSortColumns: optimizedSortColumns
                )
            }

            var additionalOrders = currentAdditionalSortOrdersAscending()
            guard additionalOrders[column]?.count != resultCount else { return self }
            additionalOrders[column] = Self.makeSortOrderAscending(store: store, column: column)
            return SearchSnapshot(
                store: store,
                modifiedDescending: modifiedDescending,
                gramIndex: gramIndex,
                pathGramShards: pathGramShards,
                pathGramExpectedRowCount: pathGramExpectedRowCount,
                nameGramIndex: nameGramIndex,
                componentGramIndex: componentGramIndex,
                extensionIndex: extensionIndex,
                childLinks: childLinks,
                nameAscending: nameAscending,
                nameDescending: nameDescending,
                sortOrdersAscending: additionalOrders,
                visibleCount: visibleCount,
                hasSortedOrder: hasSortedOrder,
                prefersDegradedSearch: prefersDegradedSearch
            )
        }

        private func additionalSortOrderAscending(for column: SortColumn) -> [Int]? {
            sortOrderLock.withLock { sortOrdersAscending[column] }
        }

        private func visibleOrder(for column: SortColumn, ascendingOrder: [Int], ascending: Bool) -> [Int] {
            let visibleAscending = sortOrderLock.withLock { visibleSortOrdersAscending[column] }
            if let visibleAscending {
                return ascending ? visibleAscending : Array(visibleAscending.reversed())
            }

            let computed = ascendingOrder.filter { store.isVisible(at: $0) }
            sortOrderLock.withLock {
                visibleSortOrdersAscending[column] = computed
            }
            return ascending ? computed : Array(computed.reversed())
        }

        func candidatePathIndices(containing tokenBytes: [UInt8]) -> [Int32]? {
            let keys = FileIndex.searchGramKeys(for: tokenBytes)
            guard !keys.isEmpty else { return nil }
            if let gramIndex {
                return Self.candidates(in: gramIndex, keys: keys)
            }
            guard !pathGramShards.isEmpty else { return nil }

            let token = String(decoding: tokenBytes, as: UTF8.self)
            return partialPathGramCandidates(
                keys: keys,
                fallbackMatches: { rowID in
                    store.normalizedPath(at: rowID).contains(token)
                }
            )
        }

        func candidatePathIndices(containingAllBytes tokenBytes: [UInt8]) -> [Int32]? {
            if let candidates = candidateIndices(in: gramIndex, containingAllBytes: tokenBytes) {
                return candidates
            }
            guard !pathGramShards.isEmpty, !tokenBytes.isEmpty else { return nil }

            var keys: [Int] = []
            keys.reserveCapacity(tokenBytes.count)
            for byte in tokenBytes {
                keys.append(FileIndex.searchGramKey(bytes: [byte], start: 0, length: 1))
            }

            return partialPathGramCandidates(
                keys: keys,
                fallbackMatches: { rowID in
                    let pathBytes = Array(store.normalizedPath(at: rowID).utf8)
                    return tokenBytes.allSatisfy { pathBytes.contains($0) }
                }
            )
        }

        private func partialPathGramCandidates(
            keys: [Int],
            fallbackMatches: (Int) -> Bool
        ) -> [Int32]? {
            let validShards = pathGramShards.filter {
                $0.index != nil
                    && $0.schemaVersion == store.schemaVersion
                    && $0.rowCount == store.count
                    && $0.range.lowerBound >= 0
                    && $0.range.lowerBound < $0.range.upperBound
                    && $0.range.upperBound <= store.count
            }.sorted {
                if $0.range.lowerBound != $1.range.lowerBound {
                    return $0.range.lowerBound < $1.range.lowerBound
                }
                return $0.range.upperBound < $1.range.upperBound
            }
            guard !validShards.isEmpty else { return nil }

            var included = Array(repeating: UInt8(0), count: store.count)
            var candidates: [Int32] = []

            func append(_ rowID: Int) {
                guard rowID >= 0, rowID < included.count, included[rowID] == 0 else { return }
                included[rowID] = 1
                candidates.append(Int32(rowID))
            }

            for shard in validShards {
                guard let index = shard.index else { continue }
                let shardCandidates = Self.candidates(in: index, keys: keys) ?? []
                for candidate in shardCandidates {
                    append(Int(candidate))
                }
            }

            var cursor = 0
            for shard in validShards {
                if cursor < shard.range.lowerBound {
                    for rowID in cursor..<shard.range.lowerBound where fallbackMatches(rowID) {
                        append(rowID)
                    }
                }
                cursor = max(cursor, shard.range.upperBound)
            }

            if cursor < store.count {
                for rowID in cursor..<store.count where fallbackMatches(rowID) {
                    append(rowID)
                }
            }

            candidates.sort()
            return candidates
        }

        func candidateIndices(
            containing tokenBytes: [UInt8],
            field: FuzzyMatcher.QueryField,
            shouldCancel: @Sendable () -> Bool = { false }
        ) -> [Int32]? {
            switch field {
            case .name:
                return candidateNameIndices(containing: tokenBytes, shouldCancel: shouldCancel)
            case .path:
                return candidatePathIndices(containing: tokenBytes)
            case .any:
                guard
                    let nameCandidates = candidateNameIndices(containing: tokenBytes, shouldCancel: shouldCancel),
                    let pathCandidates = candidatePathIndices(containing: tokenBytes)
                else {
                    return nil
                }
                return FileIndex.unionPostingLists(pathCandidates, nameCandidates, shouldCancel: shouldCancel)
            }
        }

        private static func candidates(
            in postingIndex: MappedIntPostingIndex,
            keys: [Int],
            shouldCancel: @Sendable () -> Bool = { false }
        ) -> [Int32]? {
            guard !keys.isEmpty else { return nil }

            var postings: [[Int32]] = []
            postings.reserveCapacity(keys.count)

            for key in keys {
                guard let values = postingIndex.values(for: key) else {
                    return []
                }
                postings.append(values)
            }

            postings.sort { $0.count < $1.count }
            if postings.count == 1 {
                return postings[0]
            }

            return FileIndex.intersectPostingLists(postings, shouldCancel: shouldCancel)
        }

        private static func candidates(
            in postingIndex: ComponentGramPostingIndex,
            keys: [Int],
            shouldCancel: @Sendable () -> Bool = { false }
        ) -> [Int32]? {
            switch postingIndex {
            case .combined(let combined):
                return candidates(in: combined, keys: keys, shouldCancel: shouldCancel)
            case .shared(let shared):
                return candidates(in: shared, keys: keys, shouldCancel: shouldCancel)
            }
        }

        func candidateNameIndices(
            containing tokenBytes: [UInt8],
            shouldCancel: @Sendable () -> Bool = { false }
        ) -> [Int32]? {
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

            return FileIndex.intersectPostingLists(postings, shouldCancel: shouldCancel)
        }

        func candidateNameIndices(
            containingAny tokenByteSets: [[UInt8]],
            shouldCancel: @Sendable () -> Bool = { false }
        ) -> [Int32]? {
            guard !tokenByteSets.isEmpty else { return nil }

            var candidates: [Int32] = []
            for tokenBytes in tokenByteSets {
                guard let values = candidateNameIndices(
                    containingAllBytes: tokenBytes,
                    shouldCancel: shouldCancel
                ) else {
                    return nil
                }
                guard let merged = FileIndex.unionPostingLists(
                    candidates,
                    values,
                    shouldCancel: shouldCancel
                ) else {
                    return nil
                }
                candidates = merged
            }

            return candidates
        }

        func candidateNameIndices(
            containingAllBytes tokenBytes: [UInt8],
            shouldCancel: @Sendable () -> Bool = { false }
        ) -> [Int32]? {
            candidateIndices(
                in: nameGramIndex,
                containingAllBytes: tokenBytes,
                shouldCancel: shouldCancel
            )
        }

        func candidateComponentIndices(
            containing tokenBytes: [UInt8],
            shouldCancel: @Sendable () -> Bool = { false }
        ) -> [Int32]? {
            guard let componentGramIndex else { return nil }

            let keys = FileIndex.searchGramKeys(for: tokenBytes)
            return Self.candidates(
                in: componentGramIndex,
                keys: keys,
                shouldCancel: shouldCancel
            )
        }

        func candidateComponentIndices(
            containingAllBytes tokenBytes: [UInt8],
            shouldCancel: @Sendable () -> Bool = { false }
        ) -> [Int32]? {
            guard let componentGramIndex, !tokenBytes.isEmpty else { return nil }
            let keys = tokenBytes.map { byte in
                FileIndex.searchGramKey(bytes: [byte], start: 0, length: 1)
            }
            return Self.candidates(in: componentGramIndex, keys: keys, shouldCancel: shouldCancel)
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

            func includeSubtree(startingAt start: Int) -> Bool {
                guard start >= 0, start < count, included[start] == 0 else {
                    return true
                }
                return visitSubtreeRows(startingAt: start, shouldCancel: shouldCancel) { rowID in
                    guard included[rowID] == 0 else { return true }
                    included[rowID] = 1
                    candidates.append(Int32(rowID))
                    return true
                } == true
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

        func visitSubtreeRows(
            startingAt start: Int,
            shouldCancel: @Sendable () -> Bool,
            _ body: (Int) -> Bool
        ) -> Bool? {
            guard start >= 0, start < count else { return true }
            var visited = 0

            if store.hasContiguousSubtreeRanges {
                let intervalEnd = min(store.subtreeEnd(at: start), count)
                for rowID in start..<intervalEnd {
                    visited += 1
                    if visited & 511 == 0, shouldCancel() { return nil }
                    if !body(rowID) { return false }
                }
                return true
            }

            guard let childLinks else { return nil }
            var stack = [start]
            while let rowID = stack.popLast() {
                visited += 1
                if visited & 511 == 0, shouldCancel() { return nil }
                if !body(rowID) { return false }

                var child = childLinks.firstChild[rowID]
                while child >= 0 {
                    let childRow = Int(child)
                    stack.append(childRow)
                    child = childLinks.nextSibling[childRow]
                }
            }
            return true
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
                if FileIndex.shortFuzzyPathComponentMatches(
                    store.normalizedName(at: rowID),
                    sourceText: store.name(at: rowID),
                    tokenBytes: tokenBytes
                ) {
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

            var directRows: [Int32] = []
            directRows.reserveCapacity(componentCandidates.count)
            for (offset, candidate) in componentCandidates.enumerated() {
                if offset & 511 == 0, shouldCancel() {
                    return nil
                }

                let rowID = Int(candidate)
                guard rowID >= 0, rowID < count else { continue }
                let matches = shortFuzzy
                    ? FileIndex.shortFuzzyPathComponentMatches(
                        store.normalizedName(at: rowID),
                        sourceText: store.name(at: rowID),
                        tokenBytes: tokenBytes
                    )
                    : store.normalizedName(at: rowID, contains: token)
                guard matches else { continue }

                directRows.append(candidate)
            }

            if !store.hasContiguousSubtreeRanges {
                guard let candidates = expandedPathComponentCandidates(
                    directRows: directRows,
                    rootMatches: { rowID in
                        shortFuzzy
                            ? FileIndex.shortFuzzyPathComponentMatches(
                                store.normalizedPath(at: rowID),
                                tokenBytes: tokenBytes
                            )
                            : store.normalizedPath(at: rowID).contains(token)
                    },
                    shouldCancel: shouldCancel
                ) else {
                    return nil
                }

                return RowIntervalSet.build(candidates.map { candidate in
                    let rowID = Int(candidate)
                    return RowInterval(start: rowID, end: rowID + 1)
                })
            }

            var intervals: [RowInterval] = []
            intervals.reserveCapacity(directRows.count)
            for candidate in directRows {
                let rowID = Int(candidate)
                let end = max(rowID + 1, min(store.subtreeEnd(at: rowID), count))
                intervals.append(RowInterval(start: rowID, end: end))
            }

            return RowIntervalSet.build(intervals)
        }

        private func candidateIndices(
            in postingIndex: MappedIntPostingIndex?,
            containingAllBytes tokenBytes: [UInt8],
            shouldCancel: @Sendable () -> Bool = { false }
        ) -> [Int32]? {
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

            return FileIndex.intersectPostingLists(postings, shouldCancel: shouldCancel)
        }

        func candidateIndices(
            fileExtension token: String,
            mode: FuzzyMatcher.MatchMode,
            shouldCancel: @Sendable () -> Bool = { false }
        ) -> [Int32]? {
            guard !extensionIndex.isEmpty, !token.isEmpty else { return nil }

            switch mode {
            case .exact:
                return extensionIndex[token] ?? []
            case .fuzzy:
                var candidates: [Int32] = []
                for (fileExtension, values) in extensionIndex where fileExtension == token || fileExtension.hasPrefix(token) {
                    guard let merged = FileIndex.unionPostingLists(
                        candidates,
                        values,
                        shouldCancel: shouldCancel
                    ) else {
                        return nil
                    }
                    candidates = merged
                }
                return candidates
            case .wildcard:
                if !token.contains("*"), !token.contains("?") {
                    return extensionIndex[token] ?? []
                }

                var candidates: [Int32] = []
                for (fileExtension, values) in extensionIndex where FuzzyMatcher.wildcardMatches(fileExtension, pattern: token) {
                    guard let merged = FileIndex.unionPostingLists(
                        candidates,
                        values,
                        shouldCancel: shouldCancel
                    ) else {
                        return nil
                    }
                    candidates = merged
                }
                return candidates
            }
        }

        func exactExtensionCandidatesForFastPath(
            token: String,
            mode: FuzzyMatcher.MatchMode,
            shouldCancel: @Sendable () -> Bool = { false }
        ) -> [Int32]? {
            guard !extensionIndex.isEmpty, !token.isEmpty else { return nil }

            switch mode {
            case .exact:
                return extensionIndex[token] ?? []
            case .wildcard:
                guard let alternatives = FuzzyMatcher.exactWildcardLiteralAlternatives(token) else { return nil }
                var candidates: [Int32] = []
                for alternative in alternatives {
                    guard let merged = FileIndex.unionPostingLists(
                        candidates,
                        extensionIndex[alternative] ?? [],
                        shouldCancel: shouldCancel
                    ) else {
                        return nil
                    }
                    candidates = merged
                }
                return candidates
            case .fuzzy:
                for fileExtension in extensionIndex.keys where fileExtension != token && fileExtension.hasPrefix(token) {
                    return nil
                }
                return extensionIndex[token] ?? []
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
            struct SortKey {
                let row: Int
                let modifiedTime: TimeInterval
                let normalizedName: String
            }

            var keys: [SortKey] = []
            keys.reserveCapacity(store.count)
            for row in 0..<store.count where store.isResultRow(at: row) {
                keys.append(SortKey(
                    row: row,
                    modifiedTime: store.modifiedTime(at: row),
                    normalizedName: store.normalizedName(at: row)
                ))
            }

            keys.sort {
                if $0.modifiedTime != $1.modifiedTime {
                    return $0.modifiedTime > $1.modifiedTime
                }
                if $0.normalizedName != $1.normalizedName {
                    return $0.normalizedName < $1.normalizedName
                }
                return $0.row < $1.row
            }
            return keys.map(\.row)
        }

        private static func makeNameAscending(store: RecordStore) -> [Int] {
            struct SortKey {
                let row: Int
                let normalizedName: String
            }

            var keys: [SortKey] = []
            keys.reserveCapacity(store.count)
            for row in 0..<store.count where store.isResultRow(at: row) {
                keys.append(SortKey(row: row, normalizedName: store.normalizedName(at: row)))
            }

            keys.sort {
                if $0.normalizedName != $1.normalizedName {
                    return $0.normalizedName < $1.normalizedName
                }
                return $0.row < $1.row
            }
            return keys.map(\.row)
        }

        private static func makeAdditionalSortOrdersAscending(
            store: RecordStore,
            optimizedSortColumns: Set<SortColumn>,
            persistedOrders: [SortColumn: [Int]],
            buildsMissingOrders: Bool = true
        ) -> [SortColumn: [Int]] {
            var orders: [SortColumn: [Int]] = [:]
            orders.reserveCapacity(optimizedSortColumns.count)

            for column in optimizedSortColumns where usesAdditionalSortOrder(column) {
                if let persisted = persistedOrders[column], persisted.count == (store.storedResultCount ?? store.count) {
                    orders[column] = persisted
                } else if buildsMissingOrders {
                    orders[column] = makeSortOrderAscending(store: store, column: column)
                }
            }

            return orders
        }

        private static func updatedAdditionalSortOrdersAscending(
            existing: [SortColumn: [Int]],
            changedIndices: [Int],
            changed: Set<Int>,
            store: RecordStore
        ) -> [SortColumn: [Int]] {
            guard !existing.isEmpty, !changedIndices.isEmpty else { return existing }

            var updated = existing
            for (column, order) in existing where usesAdditionalSortOrder(column) {
                let unchanged = order.filter { !changed.contains($0) }
                let changedAscending = changedIndices.sorted {
                    sortAscendingPrecedes($0, $1, store: store, column: column)
                }
                updated[column] = mergeSortOrderAscending(
                    changed: changedAscending,
                    unchanged: unchanged,
                    store: store,
                    column: column
                )
            }
            return updated
        }

        private static func usesAdditionalSortOrder(_ column: SortColumn) -> Bool {
            switch column {
            case .path, .created, .size, .fileExtension, .kind, .volume, .root:
                return true
            case .relevance, .name, .modified:
                return false
            }
        }

        private static func makeSortOrderAscending(store: RecordStore, column: SortColumn) -> [Int] {
            struct StringSortKey {
                let row: Int
                let value: String
                let normalizedName: String
                let path: String
            }

            struct TimeSortKey {
                let row: Int
                let value: TimeInterval
                let normalizedName: String
                let path: String
            }

            struct SizeSortKey {
                let row: Int
                let value: UInt64
                let normalizedName: String
                let path: String
            }

            func stringOrder(_ value: (Int) -> String) -> [Int] {
                var keys: [StringSortKey] = []
                keys.reserveCapacity(store.storedResultCount ?? store.count)
                for row in 0..<store.count where store.isResultRow(at: row) {
                    keys.append(StringSortKey(
                        row: row,
                        value: value(row),
                        normalizedName: store.normalizedName(at: row),
                        path: store.path(at: row)
                    ))
                }
                keys.sort {
                    if $0.value != $1.value {
                        return $0.value < $1.value
                    }
                    if $0.normalizedName != $1.normalizedName {
                        return $0.normalizedName < $1.normalizedName
                    }
                    return $0.path < $1.path
                }
                return keys.map(\.row)
            }

            func timeOrder(_ value: (Int) -> TimeInterval) -> [Int] {
                var keys: [TimeSortKey] = []
                keys.reserveCapacity(store.storedResultCount ?? store.count)
                for row in 0..<store.count where store.isResultRow(at: row) {
                    keys.append(TimeSortKey(
                        row: row,
                        value: value(row),
                        normalizedName: store.normalizedName(at: row),
                        path: store.path(at: row)
                    ))
                }
                keys.sort {
                    if $0.value != $1.value {
                        return $0.value < $1.value
                    }
                    if $0.normalizedName != $1.normalizedName {
                        return $0.normalizedName < $1.normalizedName
                    }
                    return $0.path < $1.path
                }
                return keys.map(\.row)
            }

            func sizeOrder() -> [Int] {
                var keys: [SizeSortKey] = []
                keys.reserveCapacity(store.storedResultCount ?? store.count)
                for row in 0..<store.count where store.isResultRow(at: row) {
                    keys.append(SizeSortKey(
                        row: row,
                        value: store.sizeBytes(at: row),
                        normalizedName: store.normalizedName(at: row),
                        path: store.path(at: row)
                    ))
                }
                keys.sort {
                    if $0.value != $1.value {
                        return $0.value < $1.value
                    }
                    if $0.normalizedName != $1.normalizedName {
                        return $0.normalizedName < $1.normalizedName
                    }
                    return $0.path < $1.path
                }
                return keys.map(\.row)
            }

            switch column {
            case .path:
                return stringOrder { store.normalizedPath(at: $0) }
            case .created:
                return timeOrder { store.createdTime(at: $0) ?? 0 }
            case .size:
                return sizeOrder()
            case .fileExtension:
                return stringOrder { store.fileExtension(at: $0) }
            case .kind:
                return stringOrder {
                    kindName(isDirectory: store.isDirectory(at: $0), fileExtension: store.fileExtension(at: $0))
                }
            case .volume:
                return stringOrder { store.volumeName(at: $0) }
            case .root:
                return stringOrder { store.rootPath(at: $0) ?? "" }
            case .name:
                return makeNameAscending(store: store)
            case .modified:
                return Array(makeModifiedDescending(store: store).reversed())
            case .relevance:
                return []
            }
        }

        private static func mergeSortOrderAscending(
            changed: [Int],
            unchanged: [Int],
            store: RecordStore,
            column: SortColumn
        ) -> [Int] {
            var merged: [Int] = []
            merged.reserveCapacity(changed.count + unchanged.count)

            var changedIndex = 0
            var unchangedIndex = 0
            while changedIndex < changed.count, unchangedIndex < unchanged.count {
                let changedRow = changed[changedIndex]
                let unchangedRow = unchanged[unchangedIndex]
                if sortAscendingPrecedes(changedRow, unchangedRow, store: store, column: column) {
                    merged.append(changedRow)
                    changedIndex += 1
                } else {
                    merged.append(unchangedRow)
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

        private static func sortAscendingPrecedes(
            _ lhs: Int,
            _ rhs: Int,
            store: RecordStore,
            column: SortColumn
        ) -> Bool {
            switch column {
            case .name:
                if store.normalizedName(at: lhs) != store.normalizedName(at: rhs) {
                    return store.normalizedName(at: lhs) < store.normalizedName(at: rhs)
                }
            case .path:
                if store.normalizedPath(at: lhs) != store.normalizedPath(at: rhs) {
                    return store.normalizedPath(at: lhs) < store.normalizedPath(at: rhs)
                }
            case .modified:
                if store.modifiedTime(at: lhs) != store.modifiedTime(at: rhs) {
                    return store.modifiedTime(at: lhs) < store.modifiedTime(at: rhs)
                }
            case .created:
                let left = store.createdTime(at: lhs) ?? 0
                let right = store.createdTime(at: rhs) ?? 0
                if left != right {
                    return left < right
                }
            case .size:
                if store.sizeBytes(at: lhs) != store.sizeBytes(at: rhs) {
                    return store.sizeBytes(at: lhs) < store.sizeBytes(at: rhs)
                }
            case .fileExtension:
                if store.fileExtension(at: lhs) != store.fileExtension(at: rhs) {
                    return store.fileExtension(at: lhs) < store.fileExtension(at: rhs)
                }
            case .kind:
                let left = kindName(isDirectory: store.isDirectory(at: lhs), fileExtension: store.fileExtension(at: lhs))
                let right = kindName(isDirectory: store.isDirectory(at: rhs), fileExtension: store.fileExtension(at: rhs))
                if left != right {
                    return left < right
                }
            case .volume:
                if store.volumeName(at: lhs) != store.volumeName(at: rhs) {
                    return store.volumeName(at: lhs) < store.volumeName(at: rhs)
                }
            case .root:
                let left = store.rootPath(at: lhs) ?? ""
                let right = store.rootPath(at: rhs) ?? ""
                if left != right {
                    return left < right
                }
            case .relevance:
                break
            }

            if store.normalizedName(at: lhs) != store.normalizedName(at: rhs) {
                return store.normalizedName(at: lhs) < store.normalizedName(at: rhs)
            }
            return store.path(at: lhs) < store.path(at: rhs)
        }

        private static func kindName(isDirectory: Bool, fileExtension: String) -> String {
            isDirectory && fileExtension == "app" ? "Application" : (isDirectory ? "Folder" : "File")
        }

        private static func makePathGramIndex(store: RecordStore) -> MappedIntPostingIndex? {
            guard store.count <= FileIndex.pathGramRecordLimit else { return nil }

            let index = makePathGramPostingMap(store: store, range: 0..<store.count)
            return try? MappedIntPostingIndex.build(from: index, temporaryName: "att-path-postings")
        }

        static func makePathGramIndex(
            store: RecordStore,
            range: Range<Int>,
            temporaryName: String
        ) -> MappedIntPostingIndex? {
            let index = makePathGramPostingMap(store: store, range: range)
            return try? MappedIntPostingIndex.build(from: index, temporaryName: temporaryName)
        }

        static func makePathGramPostingMap(store: RecordStore, range: Range<Int>) -> [Int: [Int32]] {
            var index: [Int: [Int32]] = [:]
            appendPathGramPostings(store: store, range: range, to: &index)
            return index
        }

        static func appendPathGramPostings(
            store: RecordStore,
            range: Range<Int>,
            to index: inout [Int: [Int32]]
        ) {
            var keys = Set<Int>()
            let lowerBound = max(0, range.lowerBound)
            let upperBound = min(store.count, range.upperBound)
            guard lowerBound < upperBound else { return }

            for recordIndex in lowerBound..<upperBound {
                keys.removeAll(keepingCapacity: true)
                FileIndex.collectSearchGramKeys(from: store.normalizedPath(at: recordIndex), into: &keys)

                let storedIndex = Int32(recordIndex)
                for key in keys {
                    index[key, default: []].append(storedIndex)
                }
            }
        }

        private static func makeDiagnostics(
            pathGramIndexEnabled: Bool,
            gramIndex: MappedIntPostingIndex?,
            pathGramShards: [PathGramShard],
            pathGramExpectedRowCount: Int,
            nameGramIndex: MappedIntPostingIndex?,
            componentGramIndex: ComponentGramPostingIndex?,
            extensionIndex: [String: [Int32]]
        ) -> SearchStructureDiagnostics {
            let validShardCoveredCount = pathGramShards.reduce(0) { count, shard in
                guard shard.index != nil else { return count }
                return count + shard.coveredCount
            }
            return SearchStructureDiagnostics(
                pathGramIndexEnabled: pathGramIndexEnabled,
                pathGramKeyCount: gramIndex?.keyCount ?? 0,
                pathGramPostingCount: gramIndex?.postingCount ?? 0,
                pathGramCoveredRowCount: gramIndex != nil ? pathGramExpectedRowCount : validShardCoveredCount,
                pathGramTotalRowCount: pathGramExpectedRowCount,
                nameGramKeyCount: nameGramIndex?.keyCount ?? 0,
                nameGramPostingCount: nameGramIndex?.postingCount ?? 0,
                componentGramKeyCount: componentGramIndex?.keyCount ?? 0,
                componentGramPostingCount: componentGramIndex?.postingCount ?? 0,
                extensionKeyCount: extensionIndex.count,
                extensionPostingCount: extensionIndex.values.reduce(0) { $0 + $1.count },
                simdTextVerificationEnabled: true
            )
        }

        private static func makeNameAndComponentGramIndexes(
            store: RecordStore
        ) -> (name: MappedIntPostingIndex?, component: ComponentGramPostingIndex?) {
            var sharedRows: [Int: [Int32]] = [:]
            var keys = Set<Int>()

            for recordIndex in 0..<store.count {
                keys.removeAll(keepingCapacity: true)
                FileIndex.collectSearchGramKeys(from: store.normalizedName(at: recordIndex), into: &keys)

                let storedIndex = Int32(recordIndex)
                for key in keys {
                    sharedRows[key, default: []].append(storedIndex)
                }
            }

            do {
                let sharedIndex = try MappedIntPostingIndex.build(
                    from: sharedRows,
                    temporaryName: "att-name-postings"
                )
                guard let sharedIndex else { return (name: nil, component: nil) }
                return (name: sharedIndex, component: .shared(sharedIndex))
            } catch {
                return (name: nil, component: nil)
            }
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

    private struct SearchSegment: Sendable {
        let sourceSnapshot: SearchSnapshot
        let snapshot: SearchSnapshot
        let maskedRows: PackedRowBitSet
        let liveResultCount: Int
        let liveVisibleCount: Int

        var maskedRowCount: Int { maskedRows.setBitCount }
    }

    private struct DeltaRowOwner: Sendable {
        let segmentIndex: Int
        let rowID: Int
    }

    private final class CompositeSearchState: @unchecked Sendable {
        let logicalSnapshot: SearchSnapshot
        let base: SearchSegment
        let deltaSegments: [SearchSegment]
        let deltaOwnersByPath: [String: DeltaRowOwner]
        let liveResultCount: Int
        let liveVisibleCount: Int

        init(
            logicalSnapshot: SearchSnapshot,
            base: SearchSegment,
            deltaSegments: [SearchSegment],
            deltaOwnersByPath: [String: DeltaRowOwner],
            liveResultCount: Int,
            liveVisibleCount: Int
        ) {
            self.logicalSnapshot = logicalSnapshot
            self.base = base
            self.deltaSegments = deltaSegments
            self.deltaOwnersByPath = deltaOwnersByPath
            self.liveResultCount = liveResultCount
            self.liveVisibleCount = liveVisibleCount
        }

        var segmentCount: Int { 1 + deltaSegments.count }
        var maskedRowCount: Int {
            base.maskedRowCount + deltaSegments.reduce(0) { $0 + $1.maskedRowCount }
        }
    }

    private let lock = NSLock()
    private let backgroundReconciliationCondition = NSCondition()
    private let fileManager: FileManager
    private let supportDirectory: URL
    private let snapshotURL: URL
    private let checkpointURL: URL
    private let metricsURL: URL
    private let structuralDeltaStore: StructuralDeltaStore
    private let indexQueue = DispatchQueue(label: "att.index.work", qos: .utility)
    private let checkpointQueue = DispatchQueue(label: "att.index.checkpoint", qos: .utility)
    private let metricsSaveQueue = DispatchQueue(label: "att.index.metrics", qos: .utility)
    private let checkpointPersistenceLock = NSLock()
    private let storageInsightsLock = NSLock()
    private var largeOverlayPersistRecordLimitOverride: Int?
    private var largeOverlayPersistDelayOverride: TimeInterval?
    private var largeOverlayChangedPathThresholdOverride: Int?
    private var largeOverlayDrainBackoffDelayOverride: TimeInterval?
    private var backgroundRefreshBatchLimitOverride: Int?
    private var backgroundRefreshDrainBackoffDelayOverride: TimeInterval?
    private var backgroundDirectoryScanBudgetOverride: TimeInterval?
    private var backgroundDirectoryScanVisitLimitOverride: Int?
    private var backgroundDirectoryScanEntryLimitOverride: Int?
    private var backgroundDirectoryFinalizationLimitOverride: Int?
    private var backgroundOptimizationPersistDelayOverride: TimeInterval?
    private var metadataOverlayPersistDelayOverride: TimeInterval?
    private var metadataOverlayCheckpointDelayOverride: TimeInterval?
    private var metadataOverlayPersistLimitOverride: Int?
    private var directoryUpdateEnumerationFailuresForTesting: [String: Int] = [:]
    private var fileSystemLookupFailuresForTesting: [String: (error: Int32, remaining: Int)] = [:]
    private var checkpointWriteInFlight = false
    private var usageMetricsDirtyGeneration: UInt64 = 0
    private var usageMetricsSavedGeneration: UInt64 = 0
    private var usageMetricsSaveScheduled = false
    private var usageMetricsMaintenanceSaveDelayOverride: TimeInterval?
    private var exactEmptyQuerySortLimitOverride: Int?
    private var cachedStorageInsights: IndexStorageInsights?
    private var storageInsightsRefreshInFlight = false
    private var recordsByPath: [String: FileRecord] = [:]
    private var searchSnapshot = SearchSnapshot.empty {
        didSet {
            rememberOptimizedSearchFallbackWithoutLock(searchSnapshot)
            if !(searchSnapshot.store is OverlayRecordStore) {
                compositeSearchState = nil
            }
        }
    }
    private var compositeSearchState: CompositeSearchState?
    private var structuralDelta: StructuralDelta?
    private var optimizedSearchFallbackSnapshot: SearchSnapshot?
    private var searchSnapshotRevision: UInt64 = 0
    private var roots: [String] = []
    private var exclusionRules: FileExclusionRules
    private var optimizedSortColumns = Set(SortColumn.optimizedIndexColumns)
    private var exclusionEvaluationMode: ExclusionEvaluationMode = .compiledQuery
    private var scanFrontierMode: ScanFrontierMode = .singleDirectory
    private var scanFrontierBatchSize = 1
    private var deferredOptimizationRecordThreshold = FileIndex.defaultDeferredOptimizationRecordThreshold
    private var lastScanFrontierMetrics = ScanFrontierMetrics()
    private var generation: UInt64 = 0
    private var persistRevision: UInt64 = 0
    private var structuralDeltaCompactionRevision: UInt64 = 0
    private var structuralDeltaCompactionScheduledAt: Date?
    private var structuralDeltaCompactionWriterConflictWarningDeadline: Date?
    private var structuralDeltaCompactionIsImmediate = false
    private var pendingRefreshPaths: [String: PendingRefreshWork] = [:]
    private var pendingDurabilityCompletions: [PendingRefreshCompletion] = []
    private var hasUnpersistedSnapshotChanges = false
    private var unpersistedSnapshotRevision: UInt64?
    private var durabilityRetryAttempt = 0
    private var durabilityRetryGeneration: UInt64 = 0
    private var durabilityRetryScheduled = false
    private var isRefreshDrainScheduled = false
    private var scheduledRefreshDrainPriority: IndexWorkPriority?
    private var scheduledRefreshDrainDeadline: Date?
    private var refreshDrainScheduleGeneration: UInt64 = 0
    private var refreshServiceSequence: UInt64 = 0
    private var backgroundMaintenanceEnteredAt: Date?
    private var promotedReconciliationGeneration: UInt64?
    private var optimizesSnapshotAfterPromotedRefreshDrain = false
    private var pendingReconciliationPaths = Set<String>()
    private var pendingReconciliationIncludesAllRoots = false
    private var pendingReconciliationPresentation: IndexActivityPresentation = .backgroundCatchUp
    private var activeReconciliationPaths = Set<String>()
    private var activeReconciliationIncludesAllRoots = false
    private var isReconciliationDrainScheduled = false
    private var completedRefreshBatches: UInt64 = 0
    private var completedSnapshotRebuilds: UInt64 = 0
    private var fallbackScanCount: UInt64 = 0
    private var scannedRowCount: UInt64 = 0
    private var pathMaterializationCount: UInt64 = 0
    private var activeIndexJobs = 0
    private var activeDeferredOptimizationRevision: UInt64?
    private var activePathGramBuildGeneration: UInt64?
    private var usageMetrics = IndexUsageMetrics()
    private var lastMaintenanceOperation: IndexMaintenanceOperationMetric?
    private var lastBackgroundMaintenanceSlice: IndexMaintenanceOperationMetric?
    private var deferredOptimizationReason: String?
    private var deferredOptimizationDelay: TimeInterval?
    private var deferredCheckpointReason: String?
    private var deferredCheckpointDelay: TimeInterval?
    private var snapshotLoadState = SnapshotLoadState.notStarted
    private var indexing = false
    private var reconciling = false
    private var updating = false
    private var phase: IndexPhase = .idle
    private var discoveredCount = 0
    private var searchableCount = 0
    private var optimizedCount = 0
    private var status = "Starting"
    private var lastUpdated = Date()
    private var activeOperationStartedAt: Date?
    private var lastCheckpointAt: Date?
    private var resumedFromCheckpoint = false
    private var activityPresentation: IndexActivityPresentation = .foreground
    private var publishesSearchableSnapshotsDuringScan = true
    private var statsChangedHandler: (@MainActor @Sendable (IndexStats) -> Void)?
    private var backgroundReconciliationHandler: (@MainActor @Sendable ([URL]) -> Void)?

    public init(
        fileManager: FileManager = .default,
        applicationName: String = "AllTheThings",
        loadsSnapshotImmediately: Bool = true,
        exclusionPatterns: [String] = FileExclusionRules.defaultPatterns
    ) {
        self.fileManager = fileManager
        self.exclusionRules = FileExclusionRules(patterns: exclusionPatterns)
        self.largeOverlayPersistRecordLimitOverride = nil
        self.largeOverlayPersistDelayOverride = nil
        self.largeOverlayChangedPathThresholdOverride = nil
        self.largeOverlayDrainBackoffDelayOverride = nil
        self.backgroundRefreshBatchLimitOverride = nil
        self.backgroundRefreshDrainBackoffDelayOverride = nil
        self.backgroundDirectoryScanBudgetOverride = nil
        self.backgroundDirectoryScanVisitLimitOverride = nil
        self.backgroundDirectoryScanEntryLimitOverride = nil
        self.backgroundDirectoryFinalizationLimitOverride = nil
        self.backgroundOptimizationPersistDelayOverride = nil
        self.metadataOverlayPersistDelayOverride = nil
        self.metadataOverlayCheckpointDelayOverride = nil
        self.metadataOverlayPersistLimitOverride = nil
        self.usageMetricsMaintenanceSaveDelayOverride = nil
        self.exactEmptyQuerySortLimitOverride = nil

        let supportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let supportDirectory = supportRoot.appendingPathComponent(applicationName, isDirectory: true)
        try? fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        self.supportDirectory = supportDirectory
        self.snapshotURL = SnapshotLayout.packageURL(in: supportDirectory)
        self.checkpointURL = SnapshotLayout.checkpointPackageURL(in: supportDirectory)
        self.metricsURL = supportDirectory.appendingPathComponent("index-metrics.json", isDirectory: false)
        self.structuralDeltaStore = StructuralDeltaStore(
            supportDirectory: supportDirectory,
            fileManager: fileManager
        )
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

    convenience init(
        fileManager: FileManager = .default,
        applicationName: String = "AllTheThings",
        loadsSnapshotImmediately: Bool = false,
        exclusionPatterns: [String] = FileExclusionRules.defaultPatterns,
        largeOverlayPersistRecordLimit: Int?,
        largeOverlayPersistDelay: TimeInterval?,
        largeOverlayChangedPathThreshold: Int? = nil,
        largeOverlayDrainBackoffDelay: TimeInterval? = nil,
        backgroundRefreshBatchLimit: Int? = nil,
        backgroundRefreshDrainBackoffDelay: TimeInterval? = nil,
        backgroundDirectoryScanBudget: TimeInterval? = nil,
        backgroundDirectoryScanVisitLimit: Int? = nil,
        backgroundDirectoryScanEntryLimit: Int? = nil,
        backgroundDirectoryFinalizationLimit: Int? = nil,
        backgroundOptimizationPersistDelay: TimeInterval? = nil,
        metadataOverlayPersistDelay: TimeInterval? = nil,
        metadataOverlayCheckpointDelay: TimeInterval? = nil,
        metadataOverlayPersistLimit: Int? = nil
    ) {
        precondition(!loadsSnapshotImmediately, "Large overlay persist overrides are only for deferred-load test indexes.")
        self.init(
            fileManager: fileManager,
            applicationName: applicationName,
            loadsSnapshotImmediately: loadsSnapshotImmediately,
            exclusionPatterns: exclusionPatterns
        )
        self.largeOverlayPersistRecordLimitOverride = largeOverlayPersistRecordLimit.map { max(0, $0) }
        self.largeOverlayPersistDelayOverride = largeOverlayPersistDelay.map { max(0, $0) }
        self.largeOverlayChangedPathThresholdOverride = largeOverlayChangedPathThreshold.map { max(0, $0) }
        self.largeOverlayDrainBackoffDelayOverride = largeOverlayDrainBackoffDelay.map { max(0, $0) }
        self.backgroundRefreshBatchLimitOverride = backgroundRefreshBatchLimit.map { max(1, $0) }
        self.backgroundRefreshDrainBackoffDelayOverride = backgroundRefreshDrainBackoffDelay.map { max(0, $0) }
        self.backgroundDirectoryScanBudgetOverride = backgroundDirectoryScanBudget.map { max(0, $0) }
        self.backgroundDirectoryScanVisitLimitOverride = backgroundDirectoryScanVisitLimit.map { max(0, $0) }
        self.backgroundDirectoryScanEntryLimitOverride = backgroundDirectoryScanEntryLimit.map { max(0, $0) }
        self.backgroundDirectoryFinalizationLimitOverride = backgroundDirectoryFinalizationLimit.map { max(0, $0) }
        self.backgroundOptimizationPersistDelayOverride = backgroundOptimizationPersistDelay.map { max(0, $0) }
        self.metadataOverlayPersistDelayOverride = metadataOverlayPersistDelay.map { max(0, $0) }
        self.metadataOverlayCheckpointDelayOverride = metadataOverlayCheckpointDelay.map { max(0, $0) }
        self.metadataOverlayPersistLimitOverride = metadataOverlayPersistLimit.map { max(0, $0) }
    }

    public func currentStats() -> IndexStats {
        lockedStats()
    }

    public var dataDirectoryURL: URL {
        supportDirectory
    }

    public func recordAppLaunch(appVersion: String? = nil) {
        updateUsageMetricsDeferred { metrics in
            metrics.recordAppLaunch(appVersion: appVersion)
        }
    }

    public func recordFileAction(_ action: FileActionMetric) {
        updateUsageMetricsDeferred { metrics in
            metrics.recordFileAction(action)
        }
    }

    public func recordMemorySample(bytes: UInt64) {
        updateUsageMetricsDeferred { metrics in
            metrics.recordMemorySample(bytes: bytes)
        }
    }

    public func recordEnergySample(
        completedAt: Date = Date(),
        duration: TimeInterval,
        cpuTime: TimeInterval,
        wakeups: UInt64,
        mode: EnergyUsageMode
    ) {
        guard duration > 0, cpuTime >= 0 else { return }
        updateUsageMetricsDeferred { metrics in
            _ = metrics.recordEnergySample(
                completedAt: completedAt,
                duration: duration,
                cpuTime: cpuTime,
                wakeups: wakeups,
                mode: mode
            )
        }
    }

    public func recordRecursiveRescan() {
        updateUsageMetricsDeferred { metrics in
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

    public func allOptimizedSortColumns() -> Set<SortColumn> {
        lock.withLock {
            optimizedSortColumns
        }
    }

    private func currentOptimizedSortColumns() -> Set<SortColumn> {
        lock.withLock {
            optimizedSortColumns
        }
    }

    public func updateExclusionPatterns(_ patterns: [String]) {
        let rules = FileExclusionRules(patterns: patterns)
        lock.withLock {
            exclusionRules = rules
        }
    }

    public func updateOptimizedSortColumns(_ columns: Set<SortColumn>) {
        let sanitized = columns.intersection(Set(SortColumn.optimizedIndexColumns))
        let shouldRebuild = lock.withLock { () -> Bool in
            guard optimizedSortColumns != sanitized else { return false }
            optimizedSortColumns = sanitized
            DiagnosticLogger.shared.log(
                category: "index",
                event: "index.optimizedSortColumnsChanged",
                fields: [
                    "columnCount": .publicInt(sanitized.count),
                    "columns": .publicStringArray(
                        SortColumn.optimizedIndexColumns
                            .filter { sanitized.contains($0) }
                            .map(\.rawValue)
                    )
                ]
            )
            return searchSnapshot.resultCount > 0
        }

        guard shouldRebuild else { return }
        indexQueue.async { [weak self] in
            self?.rebuildEnabledSortOrdersIfPossible()
        }
    }

    private func rebuildEnabledSortOrdersIfPossible() {
        let state = lock.withLock {
            (
                snapshot: searchSnapshot,
                revision: searchSnapshotRevision,
                columns: optimizedSortColumns,
                canRebuild: !indexing && !reconciling && !updating && !isRefreshDrainScheduled
            )
        }
        guard state.canRebuild, state.snapshot.resultCount > 0 else { return }

        let optimizedSnapshot = state.snapshot.addingOptimizedSortOrders(state.columns)
        let installed = lock.withLock { () -> Bool in
            guard searchSnapshot === state.snapshot, searchSnapshotRevision == state.revision else {
                return false
            }
            guard optimizedSnapshot !== state.snapshot else {
                return true
            }
            searchSnapshot = optimizedSnapshot
            advanceSearchSnapshotRevisionPreservingDurabilityWithoutLock()
            lastUpdated = Date()
            return true
        }

        guard installed else { return }
        publishStats()
        schedulePersist(delay: 0)
    }

    private func rebuildOptimizedSortOrderIfPossible(for column: SortColumn) {
        let state = lock.withLock {
            (
                snapshot: searchSnapshot,
                revision: searchSnapshotRevision,
                columns: optimizedSortColumns,
                canRebuild: !indexing && !reconciling && !updating && !isRefreshDrainScheduled
            )
        }
        guard state.canRebuild, state.snapshot.resultCount > 0 else { return }

        let optimizedSnapshot = state.snapshot.addingOptimizedSortOrder(
            for: column,
            optimizedSortColumns: state.columns
        )
        let installed = lock.withLock { () -> Bool in
            guard searchSnapshot === state.snapshot, searchSnapshotRevision == state.revision else {
                return false
            }
            guard optimizedSnapshot !== state.snapshot else {
                return true
            }
            searchSnapshot = optimizedSnapshot
            advanceSearchSnapshotRevisionPreservingDurabilityWithoutLock()
            lastUpdated = Date()
            return true
        }

        guard installed else { return }
        publishStats()
        persistOptimizedSortOrderSidecarIfPossible(for: column, snapshot: optimizedSnapshot)
    }

    private func persistOptimizedSortOrderSidecarIfPossible(for column: SortColumn, snapshot: SearchSnapshot) {
        guard snapshot.store.kind == .mapped else { return }
        guard let fileName = Self.sortOrderFileName(for: column) else { return }
        guard fileManager.fileExists(atPath: snapshotURL.path) else { return }
        guard let order = snapshot.persistedSortOrderAscending(for: column), order.count == snapshot.resultCount else {
            return
        }

        let sidecarURL = snapshotURL.appendingPathComponent(fileName, isDirectory: false)
        do {
            try CompactSearchStructureFiles.writeModifiedOrder(order, to: sidecarURL)
            invalidateStorageInsightsCache()
            DiagnosticLogger.shared.log(
                category: "index",
                event: "index.optimizedSortOrderSidecarPersisted",
                fields: [
                    "sortColumn": .publicString(column.rawValue),
                    "recordCount": .publicInt(order.count)
                ]
            )
        } catch {
            DiagnosticLogger.shared.log(
                category: "index",
                event: "index.optimizedSortOrderSidecarPersistFailed",
                fields: [
                    "sortColumn": .publicString(column.rawValue),
                    "error": .privateString(error.localizedDescription)
                ]
            )
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

        let storage = currentStorageInsights()
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

    public func flushUsageMetrics() {
        metricsSaveQueue.sync {
            savePendingUsageMetricsIfNeeded()
        }
    }

    public func currentRootInsights() -> [IndexRootInsight] {
        let state = lock.withLock {
            (
                snapshot: searchSnapshot,
                roots: roots
            )
        }
        return Self.rootInsights(
            snapshot: state.snapshot,
            roots: state.roots,
            estimatedIndexBytes: 0
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

        flushUsageMetrics()

        try indexQueue.sync {
            try removePersistedIndexFiles()
            invalidateStorageInsightsCache()
            lock.withLock {
                recordsByPath.removeAll(keepingCapacity: false)
                clearOptimizedSearchFallbackWithoutLock()
                searchSnapshot = .empty
                searchSnapshotRevision &+= 1
                discoveredCount = 0
                searchableCount = 0
                optimizedCount = 0
                phase = .idle
                status = "Cached index cleared"
                lastUpdated = Date()
                activeOperationStartedAt = nil
                lastCheckpointAt = nil
                resumedFromCheckpoint = false
            }
        }
        publishStats()
    }

    public func replaceRootsAndRebuild(_ rootURLs: [URL], mode: RebuildMode = .fresh) {
        let canonicalRoots = canonicalizedRoots(rootURLs)
        guard canonicalRoots.count <= Self.maximumIndexedRootCount else {
            publishRootLimitFailure(count: canonicalRoots.count)
            return
        }
        DiagnosticLogger.shared.log(
            category: "index",
            event: "index.rebuildRequested",
            fields: [
                "mode": .publicString(Self.diagnosticRebuildModeString(mode)),
                "rootCount": .publicInt(canonicalRoots.count)
            ],
            diagnosticFields: [
                "roots": .pathArray(canonicalRoots.map(\.path))
            ]
        )
        let rebuildStarted = Date()
        let currentGeneration = lock.withLock { () -> UInt64 in
            generation &+= 1
            activePathGramBuildGeneration = nil
            snapshotLoadState = .finished
            clearOptimizedSearchFallbackWithoutLock()
            roots = canonicalRoots.map(\.path)
            indexing = true
            reconciling = false
            updating = false
            activityPresentation = .foreground
            clearActiveReconciliationWithoutLock()
            phase = .scanning
            discoveredCount = 0
            searchableCount = 0
            optimizedCount = 0
            status = "Indexing \(canonicalRoots.count) scope\(canonicalRoots.count == 1 ? "" : "s")"
            lastUpdated = Date()
            activeOperationStartedAt = rebuildStarted
            lastCheckpointAt = nil
            resumedFromCheckpoint = false
            return generation
        }
        wakeBackgroundReconciliation()

        publishStats()

        indexQueue.async { [weak self] in
            self?.rebuild(roots: canonicalRoots, mode: mode, generation: currentGeneration, started: rebuildStarted)
        }
    }

    @discardableResult
    public func loadSnapshotInBackground() -> Bool {
        guard beginSnapshotLoad() else { return false }
        DiagnosticLogger.shared.log(category: "index", event: "index.snapshotLoadRequested")
        let generationAtStart = currentGeneration()

        indexQueue.async { [weak self] in
            self?.loadSnapshotAfterBegin(generationAtStart: generationAtStart)
        }

        return true
    }

    public func hasResumableCheckpoint(for rootURLs: [URL]) -> Bool {
        let canonicalRoots = canonicalizedRoots(rootURLs)
        guard canonicalRoots.count <= Self.maximumIndexedRootCount else { return false }
        let checkpoint = matchingScanCheckpointState(
            roots: canonicalRoots.map(\.path),
            exclusionPatterns: lock.withLock { exclusionRules.patterns },
            removesInvalidCheckpoint: true
        )
        return checkpoint != nil
    }

    @discardableResult
    public func reconcileIndexedRootsInBackground(
        rootURLs requestedRootURLs: [URL]? = nil,
        activityPresentation requestedPresentation: IndexActivityPresentation = .foreground
    ) -> ReconciliationRequestResult {
        let reconcileStarted = Date()
        let state = lock.withLock {
            (
                rootPaths: roots,
                exclusions: exclusionRules
            )
        }
        let allRootURLs = state.rootPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let rootURLs: [URL]
        if let requestedRootURLs {
            rootURLs = Self.reconciliationScopeURLs(
                for: requestedRootURLs.map { $0.standardizedFileURL.path },
                within: state.rootPaths
            )
        } else {
            rootURLs = allRootURLs
        }
        guard !rootURLs.isEmpty else { return .ignored }
        guard allRootURLs.count <= Self.maximumIndexedRootCount else {
            publishRootLimitFailure(count: allRootURLs.count)
            return .ignored
        }
        let scopePaths = rootURLs.map(\.path)
        let reconcilesAllRoots = Set(scopePaths) == Set(state.rootPaths)
        DiagnosticLogger.shared.log(
            category: "index",
            event: "index.reconcileRequested",
            fields: [
                "reconcilesAllRoots": .publicBool(reconcilesAllRoots),
                "activityPresentation": .publicString(requestedPresentation.rawValue),
                "scopeCount": .publicInt(rootURLs.count)
            ],
            diagnosticFields: [
                "scopes": .pathArray(scopePaths)
            ]
        )

        var currentGeneration: UInt64?
        let result = lock.withLock { () -> ReconciliationRequestResult in
            guard !indexing else {
                let uncoveredScopePaths = uncoveredReconciliationPathsWithoutLock(
                    scopePaths: scopePaths,
                    reconcilesAllRoots: reconcilesAllRoots
                )
                guard !uncoveredScopePaths.isEmpty else {
                    return .coveredByActive
                }
                queuePendingReconciliationWithoutLock(
                    scopePaths: reconcilesAllRoots ? scopePaths : uncoveredScopePaths,
                    reconcilesAllRoots: reconcilesAllRoots,
                    activityPresentation: requestedPresentation
                )
                return .queued
            }

            generation &+= 1
            activePathGramBuildGeneration = nil
            indexing = true
            reconciling = true
            updating = false
            activityPresentation = requestedPresentation
            phase = .scanning
            status = Self.reconciliationStatus(
                reconcilesAllRoots: reconcilesAllRoots,
                activityPresentation: requestedPresentation
            )
            discoveredCount = 0
            searchableCount = searchSnapshot.resultCount
            activeOperationStartedAt = reconcileStarted
            resumedFromCheckpoint = false
            lastUpdated = Date()
            activeReconciliationPaths = Set(scopePaths)
            activeReconciliationIncludesAllRoots = reconcilesAllRoots
            currentGeneration = generation
            return .started
        }
        guard result == .started, let currentGeneration else {
            let event = result == .coveredByActive ? "index.reconcileCoveredByActive" : "index.reconcileCoalesced"
            DiagnosticLogger.shared.log(
                category: "index",
                event: event,
                fields: [
                    "reconcilesAllRoots": .publicBool(reconcilesAllRoots),
                    "activityPresentation": .publicString(requestedPresentation.rawValue),
                    "scopeCount": .publicInt(scopePaths.count)
                ],
                diagnosticFields: [
                    "scopes": .pathArray(scopePaths)
                ]
            )
            return result
        }
        publishStats()

        indexQueue.async { [weak self] in
            self?.reconcile(
                roots: rootURLs,
                allRootPaths: state.rootPaths,
                exclusions: state.exclusions,
                generation: currentGeneration,
                started: reconcileStarted,
                activityPresentation: requestedPresentation
            )
        }
        return .started
    }

    public func update(
        paths rawPaths: [String],
        priority: IndexWorkPriority = .interactive,
        completion: (@Sendable () -> Void)? = nil
    ) {
        queueUpdate(
            exactPaths: [],
            recursivePaths: rawPaths,
            priority: priority,
            completion: completion
        )
    }

    @_spi(ATTInternal)
    public func update(
        exactPaths rawExactPaths: [String],
        recursivePaths rawRecursivePaths: [String],
        priority: IndexWorkPriority = .interactive,
        completion: (@Sendable () -> Void)? = nil
    ) {
        queueUpdate(
            exactPaths: rawExactPaths,
            recursivePaths: rawRecursivePaths,
            priority: priority,
            completion: completion
        )
    }

    private func queueUpdate(
        exactPaths rawExactPaths: [String],
        recursivePaths rawRecursivePaths: [String],
        priority: IndexWorkPriority,
        completion: (@Sendable () -> Void)?
    ) {
        let requestedRecursivePaths = Set(rawRecursivePaths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
        let requestedExactPaths = Set(rawExactPaths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }).subtracting(requestedRecursivePaths)
        let requestedPaths = requestedExactPaths.union(requestedRecursivePaths)
        let rootPaths = lock.withLock { roots }
        let paths = Set(requestedPaths.filter { path in
            Self.path(path, isWithinAnyRoot: rootPaths)
        })
        let recursivePaths = requestedRecursivePaths.intersection(paths)
        let exactPaths = requestedExactPaths.intersection(paths)
        let discardedPaths = requestedPaths.subtracting(paths)
        if !discardedPaths.isEmpty {
            DiagnosticLogger.shared.log(
                level: .warning,
                category: "index",
                event: "index.updateDiscardedOutsideRoots",
                fields: [
                    "requestedPathCount": .publicInt(requestedPaths.count),
                    "discardedPathCount": .publicInt(discardedPaths.count)
                ],
                diagnosticFields: [
                    "paths": .pathArray(Array(discardedPaths))
                ]
            )
        }
        guard !paths.isEmpty else {
            completion?()
            return
        }
        DiagnosticLogger.shared.log(
            category: "index",
            event: "index.updateQueued",
            fields: [
                "pathCount": .publicInt(paths.count),
                "exactPathCount": .publicInt(exactPaths.count),
                "recursivePathCount": .publicInt(recursivePaths.count),
                "priority": .publicString(priority.rawValue)
            ],
            diagnosticFields: [
                "paths": .pathArray(Array(paths))
            ]
        )

        let queuedAt = Date()
        let completionTracker = completion.map {
            PendingRefreshCompletion(pathCount: paths.count, completion: $0)
        }
        lock.withLock {
            queuePendingRefreshPathsWithoutLock(
                exactPaths,
                priority: priority,
                recursivelyScansDirectory: false,
                queuedAt: queuedAt,
                completion: completionTracker
            )
            queuePendingRefreshPathsWithoutLock(
                recursivePaths,
                priority: priority,
                recursivelyScansDirectory: true,
                queuedAt: queuedAt,
                completion: completionTracker
            )
        }
        scheduleUpdateDrainIfNeeded(delay: .milliseconds(150))
    }

    private static func path(_ path: String, isWithinAnyRoot rootPaths: [String]) -> Bool {
        rootPaths.contains { root in
            root == "/" || path == root || path.hasPrefix(root + "/")
        }
    }

    public func refresh(paths rawPaths: [String]) {
        update(paths: rawPaths)
    }

    @_spi(ATTInternal)
    public func setBackgroundMaintenanceEnabled(_ enabled: Bool) {
        let changed = lock.withLock { () -> Bool in
            let wasEnabled = backgroundMaintenanceEnteredAt != nil
            if enabled {
                promotedReconciliationGeneration = nil
            }
            guard wasEnabled != enabled else { return false }

            backgroundMaintenanceEnteredAt = enabled ? Date() : nil
            if enabled {
                for path in pendingRefreshPaths.keys {
                    guard var work = pendingRefreshPaths[path] else { continue }
                    work.demote()
                    pendingRefreshPaths[path] = work
                }
            }
            return true
        }

        guard changed else { return }
        wakeBackgroundReconciliation()
        DiagnosticLogger.shared.log(
            category: "index",
            event: "index.backgroundMaintenanceModeChanged",
            fields: ["enabled": .publicBool(enabled)]
        )
    }

    public func promoteBackgroundMaintenance() {
        // A reconciliation owns indexQueue while its scan workers are parked.
        // Mark it as promoted and wake its workers synchronously; the queued
        // refresh promotion below cannot run until they have released the queue.
        lock.withLock {
            if indexing, reconciling {
                promotedReconciliationGeneration = generation
            }
        }
        wakeBackgroundReconciliation()
        indexQueue.async { [weak self] in
            self?.promoteBackgroundMaintenanceOnIndexQueue()
        }
    }

    private func promoteBackgroundMaintenanceOnIndexQueue() {
        let promoted = lock.withLock { () -> (
            pendingPathCount: Int,
            hasPendingRefreshes: Bool,
            shouldOptimizeSnapshot: Bool
        ) in
            var promotedCount = 0
            for path in pendingRefreshPaths.keys {
                guard var work = pendingRefreshPaths[path], work.priority == .background else { continue }
                work.promote()
                pendingRefreshPaths[path] = work
                promotedCount += 1
            }

            let shouldOptimizeSnapshot = !indexing
                && searchSnapshot.store.kind == .overlay
                && !searchSnapshot.isOptimizedForSearch
                && !hasDurableStructuralDeltaBelowCompactionThresholdWithoutLock()
            if shouldOptimizeSnapshot, !pendingRefreshPaths.isEmpty {
                optimizesSnapshotAfterPromotedRefreshDrain = true
            }

            return (
                promotedCount,
                !pendingRefreshPaths.isEmpty,
                shouldOptimizeSnapshot
            )
        }

        guard promoted.pendingPathCount > 0 || promoted.shouldOptimizeSnapshot else { return }
        DiagnosticLogger.shared.log(
            category: "index",
            event: "index.backgroundMaintenancePromoted",
            fields: [
                "pendingPathCount": .publicInt(promoted.pendingPathCount),
                "schedulesRefreshDrain": .publicBool(promoted.hasPendingRefreshes),
                "schedulesOptimization": .publicBool(promoted.shouldOptimizeSnapshot)
            ]
        )

        if promoted.hasPendingRefreshes {
            scheduleUpdateDrainIfNeeded(delay: .milliseconds(0))
        } else if promoted.shouldOptimizeSnapshot {
            schedulePersist(delay: 0)
        }
    }

    public func prioritizeSearchOptimization(for sortColumn: SortColumn) {
        let state = lock.withLock {
            (
                shouldSchedulePersist: !indexing
                    && !reconciling
                    && !updating
                    && activeDeferredOptimizationRevision == nil
                    && searchSnapshot.store.kind != .mapped
                    && !searchSnapshot.isOptimizedForSearch
                    && !hasDurableStructuralDeltaBelowCompactionThresholdWithoutLock()
                    && searchSnapshot.resultCount > 0,
                shouldBuildSortOrder: !indexing
                    && !reconciling
                    && !updating
                    && searchSnapshot.isOptimizedForSearch
                    && searchSnapshot.resultCount > 0
                    && !searchSnapshot.hasOptimizedSortOrder(
                        for: sortColumn,
                        optimizedSortColumns: optimizedSortColumns
                    )
            )
        }
        guard state.shouldSchedulePersist || state.shouldBuildSortOrder else { return }

        DiagnosticLogger.shared.log(
            category: "index",
            event: "index.searchOptimizationPrioritized",
            fields: [
                "sortColumn": .publicString(sortColumn.rawValue),
                "buildsSortOrder": .publicBool(state.shouldBuildSortOrder)
            ]
        )
        if state.shouldBuildSortOrder {
            indexQueue.async { [weak self] in
                self?.rebuildOptimizedSortOrderIfPossible(for: sortColumn)
            }
        } else {
            schedulePersist(delay: 0)
        }
    }

    private func requestBackgroundReconciliation() {
        let state = lock.withLock {
            (
                rootPaths: roots,
                handler: backgroundReconciliationHandler
            )
        }
        let rootURLs = state.rootPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard !rootURLs.isEmpty else { return }

        guard let handler = state.handler else {
            reconcileIndexedRootsInBackground()
            return
        }

        Task { @MainActor in
            handler(rootURLs)
        }
    }

    private static func reconciliationStatus(
        reconcilesAllRoots: Bool,
        activityPresentation: IndexActivityPresentation
    ) -> String {
        switch activityPresentation {
        case .foreground:
            reconcilesAllRoots ? "Reconciling index" : "Reconciling changed folders"
        case .backgroundCatchUp:
            "Catching up changes"
        }
    }

    private static func mergedPresentation(
        _ lhs: IndexActivityPresentation,
        _ rhs: IndexActivityPresentation
    ) -> IndexActivityPresentation {
        lhs == .foreground || rhs == .foreground ? .foreground : .backgroundCatchUp
    }

    private func uncoveredReconciliationPathsWithoutLock(
        scopePaths: [String],
        reconcilesAllRoots: Bool
    ) -> [String] {
        guard reconciling else { return scopePaths }
        guard !activeReconciliationIncludesAllRoots else { return [] }
        guard !activeReconciliationPaths.isEmpty else { return scopePaths }
        guard !reconcilesAllRoots else { return scopePaths }

        return scopePaths.filter { scopePath in
            !activeReconciliationPaths.contains { activePath in
                scopePath == activePath || scopePath.hasPrefix(activePath + "/")
            }
        }
    }

    private func clearActiveReconciliationWithoutLock() {
        activeReconciliationPaths.removeAll(keepingCapacity: false)
        activeReconciliationIncludesAllRoots = false
    }

    private func rememberOptimizedSearchFallbackWithoutLock(_ snapshot: SearchSnapshot) {
        guard snapshot.resultCount > 0, snapshot.isOptimizedForSearch else { return }
        optimizedSearchFallbackSnapshot = snapshot
    }

    private func clearOptimizedSearchFallbackWithoutLock() {
        optimizedSearchFallbackSnapshot = nil
    }

    private func queuePendingReconciliationWithoutLock(
        scopePaths: [String],
        reconcilesAllRoots: Bool,
        activityPresentation: IndexActivityPresentation
    ) {
        pendingReconciliationPresentation = Self.mergedPresentation(
            pendingReconciliationPresentation,
            activityPresentation
        )
        if reconcilesAllRoots {
            pendingReconciliationIncludesAllRoots = true
            pendingReconciliationPaths.removeAll(keepingCapacity: false)
        } else if !pendingReconciliationIncludesAllRoots {
            pendingReconciliationPaths.formUnion(scopePaths)
        }
    }

    private func schedulePendingReconciliationDrainIfNeeded() {
        let pending = lock.withLock { () -> (scopeURLs: [URL], activityPresentation: IndexActivityPresentation)? in
            guard
                !indexing,
                pendingRefreshPaths.isEmpty,
                !isRefreshDrainScheduled,
                !isReconciliationDrainScheduled,
                pendingReconciliationIncludesAllRoots || !pendingReconciliationPaths.isEmpty
            else {
                return nil
            }

            let requestedPaths = pendingReconciliationIncludesAllRoots ? roots : Array(pendingReconciliationPaths)
            let presentation = pendingReconciliationPresentation
            pendingReconciliationIncludesAllRoots = false
            pendingReconciliationPaths.removeAll(keepingCapacity: false)
            pendingReconciliationPresentation = .backgroundCatchUp

            let urls = Self.reconciliationScopeURLs(for: requestedPaths, within: roots)
            guard !urls.isEmpty else { return nil }
            isReconciliationDrainScheduled = true
            return (urls, presentation)
        }

        guard let pending else { return }
        indexQueue.async { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                self.isReconciliationDrainScheduled = false
            }
            self.reconcileIndexedRootsInBackground(
                rootURLs: pending.scopeURLs,
                activityPresentation: pending.activityPresentation
            )
        }
    }

    private func makeSearchSegment(
        source: SearchSnapshot,
        maskedRows: PackedRowBitSet
    ) -> SearchSegment {
        var maskedResultCount = 0
        var maskedVisibleCount = 0
        maskedRows.forEachSetIndex { rowID in
            guard source.store.isResultRow(at: rowID) else { return }
            maskedResultCount += 1
            if source.isVisible(at: rowID) {
                maskedVisibleCount += 1
            }
        }

        let physicalVisibleCount = source.visibleResultCount
            ?? (0..<source.count).reduce(into: 0) { count, rowID in
                if source.store.isResultRow(at: rowID), source.isVisible(at: rowID) {
                    count += 1
                }
            }
        return SearchSegment(
            sourceSnapshot: source,
            snapshot: source.maskingRows(maskedRows),
            maskedRows: maskedRows,
            liveResultCount: max(source.resultCount - maskedResultCount, 0),
            liveVisibleCount: max(physicalVisibleCount - maskedVisibleCount, 0)
        )
    }

    private static func deltaOwners(
        for records: [FileRecord],
        segmentIndex: Int
    ) -> [String: DeltaRowOwner] {
        Dictionary(uniqueKeysWithValues: records.enumerated().map {
            ($0.element.path, DeltaRowOwner(segmentIndex: segmentIndex, rowID: $0.offset))
        })
    }

    private static func sharesRowIdentity(_ snapshot: SearchSnapshot, with store: RecordStore) -> Bool {
        guard snapshot.count == store.count, snapshot.store.schemaVersion == store.schemaVersion else {
            return false
        }
        guard snapshot.count > 0 else { return true }
        let last = snapshot.count - 1
        return snapshot.store.recordID(at: 0) == store.recordID(at: 0)
            && snapshot.store.recordID(at: last) == store.recordID(at: last)
    }

    private func makeDeltaSourceSnapshot(records: [FileRecord], roots: [String]) -> SearchSnapshot {
        SearchSnapshot(
            records: records,
            roots: roots,
            buildsSearchStructures: true,
            buildsPathGramIndex: true,
            optimizedSortColumns: currentOptimizedSortColumns(),
            prefersDegradedSearch: false
        )
    }

    private func makeCompositeSearchState(
        logicalSnapshot: SearchSnapshot,
        optimizedBase: SearchSnapshot?,
        roots: [String],
        previousState: CompositeSearchState?,
        changedUpserts: [FileRecord],
        changedTombstonedPaths: [String],
        forceConsolidation: Bool = false
    ) -> CompositeSearchState? {
        guard let overlay = logicalSnapshot.store as? OverlayRecordStore else { return nil }

        let previousUsesSameBase = previousState.map {
            Self.sharesRowIdentity($0.base.sourceSnapshot, with: overlay.searchBaseStore)
        } == true
        let baseSource = previousUsesSameBase ? previousState?.base.sourceSnapshot : optimizedBase
        guard
            let baseSource,
            baseSource.isOptimizedForSearch,
            Self.sharesRowIdentity(baseSource, with: overlay.searchBaseStore)
        else {
            return nil
        }

        var baseMask = PackedRowBitSet(bitCount: baseSource.count)
        for rowID in overlay.deletedBaseRows where rowID >= 0 && rowID < baseSource.count {
            baseMask.insert(rowID)
        }
        let baseSegment = makeSearchSegment(source: baseSource, maskedRows: baseMask)

        var sourceSnapshots: [SearchSnapshot] = []
        var masks: [PackedRowBitSet] = []
        var owners: [String: DeltaRowOwner] = [:]

        if previousUsesSameBase, let previousState, !forceConsolidation {
            sourceSnapshots = previousState.deltaSegments.map(\.sourceSnapshot)
            masks = previousState.deltaSegments.map(\.maskedRows)
            owners = previousState.deltaOwnersByPath

            let changedPaths = Set(changedUpserts.map(\.path)).union(changedTombstonedPaths)
            for path in changedPaths {
                if let owner = owners.removeValue(forKey: path),
                   owner.segmentIndex >= 0,
                   owner.segmentIndex < masks.count,
                   owner.rowID >= 0,
                   owner.rowID < masks[owner.segmentIndex].bitCount {
                    masks[owner.segmentIndex].insert(owner.rowID)
                }
            }

            var liveBatchByPath: [String: FileRecord] = [:]
            liveBatchByPath.reserveCapacity(changedUpserts.count)
            for record in changedUpserts {
                if let current = overlay.searchUpsert(forPath: record.path) {
                    liveBatchByPath[record.path] = current
                }
            }
            let liveBatch = liveBatchByPath.values.sorted { $0.path < $1.path }
            if !liveBatch.isEmpty {
                let segmentIndex = sourceSnapshots.count
                sourceSnapshots.append(makeDeltaSourceSnapshot(records: liveBatch, roots: roots))
                masks.append(PackedRowBitSet(bitCount: liveBatch.count))
                for (rowID, record) in liveBatch.enumerated() {
                    owners[record.path] = DeltaRowOwner(segmentIndex: segmentIndex, rowID: rowID)
                }
            }
        } else if !overlay.searchUpserts.isEmpty {
            let records = overlay.searchUpserts
            sourceSnapshots = [makeDeltaSourceSnapshot(records: records, roots: roots)]
            masks = [PackedRowBitSet(bitCount: records.count)]
            owners = Self.deltaOwners(for: records, segmentIndex: 0)
        }

        let physicalDeltaCount = sourceSnapshots.reduce(0) { $0 + $1.resultCount }
        let shadowedDeltaCount = masks.reduce(0) { $0 + $1.setBitCount }
        let shouldConsolidate = forceConsolidation
            || sourceSnapshots.count > 8
            || (shadowedDeltaCount >= 4_096 && shadowedDeltaCount * 4 >= max(physicalDeltaCount, 1))
            || owners.count != overlay.searchUpserts.count
        if shouldConsolidate {
            let records = overlay.searchUpserts
            if records.isEmpty {
                sourceSnapshots = []
                masks = []
                owners = [:]
            } else {
                sourceSnapshots = [makeDeltaSourceSnapshot(records: records, roots: roots)]
                masks = [PackedRowBitSet(bitCount: records.count)]
                owners = Self.deltaOwners(for: records, segmentIndex: 0)
            }
        }

        let deltaSegments = zip(sourceSnapshots, masks).map { source, mask in
            makeSearchSegment(source: source, maskedRows: mask)
        }
        let liveVisibleCount = baseSegment.liveVisibleCount
            + deltaSegments.reduce(0) { $0 + $1.liveVisibleCount }
        return CompositeSearchState(
            logicalSnapshot: logicalSnapshot,
            base: baseSegment,
            deltaSegments: deltaSegments,
            deltaOwnersByPath: owners,
            liveResultCount: logicalSnapshot.resultCount,
            liveVisibleCount: liveVisibleCount
        )
    }

    public func search(_ request: SearchRequest, maxResults: Int = 2_000) -> SearchResponse {
        for _ in 0..<3 {
            if let response = search(request, maxResults: maxResults, shouldCancel: { false }) {
                return response
            }
        }
        return SearchResponse(results: [], totalMatches: 0, elapsed: 0)
    }

    private static func shouldPromoteSortedOrderForEmptyQuery(
        snapshot: SearchSnapshot,
        request: SearchRequest,
        parsedQuery: FuzzyMatcher.ParsedQuery,
        maxResults: Int,
        canPromoteSortedOrder: Bool,
        optimizedSortColumns: Set<SortColumn>
    ) -> Bool {
        guard canPromoteSortedOrder, parsedQuery.isEmpty, maxResults > 0 else {
            return false
        }
        guard optimizedSortColumns.contains(request.sort.column) || request.sort.column == .relevance else {
            return false
        }

        switch request.sort.column {
        case .name:
            return !snapshot.hasSortedOrder
        case .modified, .relevance:
            return !snapshot.hasModifiedSortOrder
        case .path, .created, .size, .fileExtension, .kind, .volume, .root:
            return false
        }
    }

    private static func shouldUseDegradedSearch(snapshot: SearchSnapshot, isRefreshActive: Bool) -> Bool {
        snapshot.prefersDegradedSearch || isRefreshActive
    }

    private static func sortAndLimit(
        _ results: inout [SearchResult],
        request: SearchRequest,
        maxResults: Int
    ) {
        results.sort { compare($0, $1, sort: request.sort, queryIsEmpty: false) }
        if results.count > maxResults {
            results.removeSubrange(maxResults..<results.count)
        }
    }

    private static func responseByMergingRefreshResults(
        _ response: SearchResponse,
        results: [SearchResult],
        totalMatches: Int,
        additionalCandidateCount: Int,
        additionalScanCount: Int
    ) -> SearchResponse {
        let profile = response.executionProfile
        return SearchResponse(
            results: results,
            totalMatches: max(totalMatches, 0),
            elapsed: response.elapsed,
            snapshotRevision: response.snapshotRevision,
            usesIndexedCandidates: response.usesIndexedCandidates,
            completeness: response.completeness,
            executionProfile: SearchExecutionProfile(
                executionPath: profile.executionPath,
                indexesUsed: profile.indexesUsed,
                candidateCount: profile.candidateCount + additionalCandidateCount,
                scannedRowCount: profile.scannedRowCount + additionalScanCount,
                didFallbackToFullScan: profile.didFallbackToFullScan,
                wasCancelled: profile.wasCancelled,
                wasStaleRetry: profile.wasStaleRetry,
                elapsed: profile.elapsed
            )
        )
    }

    private func mergingPendingExactRefreshes(
        into response: SearchResponse,
        pendingExactPaths: [String],
        currentSnapshot: SearchSnapshot,
        rootPaths: [String],
        request: SearchRequest,
        parsedQuery: FuzzyMatcher.ParsedQuery,
        maxResults: Int,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        // Exact FSEvents can wait behind a long reconciliation. Match their paths
        // cheaply, then stat only a bounded candidate set before exposing results.
        guard !pendingExactPaths.isEmpty, maxResults > 0 else { return response }

        var candidates: [SearchResult] = []
        let candidateLimit = min(maxResults, Self.pendingRefreshSearchResultLimit)
        for (offset, path) in pendingExactPaths.enumerated() {
            if offset.isMultiple(of: 64), shouldCancel() {
                return nil
            }
            guard currentSnapshot.store.rowID(forPath: path) == nil else { continue }

            let record = Self.pendingRefreshSearchCandidate(path: path)
            guard let explanation = FuzzyMatcher.explain(record: record, parsedQuery: parsedQuery) else {
                continue
            }
            let rootPath = rootPaths.first {
                RootAttributionMatcher.matches(path: path, rootPath: $0)
            }
            candidates.append(SearchResult(
                record: record,
                score: explanation.score,
                match: explanation,
                rootPath: rootPath
            ))
            if candidates.count > candidateLimit * 5 {
                Self.sortAndLimit(&candidates, request: request, maxResults: candidateLimit)
            }
        }

        guard !candidates.isEmpty else { return response }
        Self.sortAndLimit(&candidates, request: request, maxResults: candidateLimit)

        let volumeNameCache = ScanVolumeNameCache()
        var pendingResults: [SearchResult] = []
        pendingResults.reserveCapacity(candidates.count)
        for (offset, candidate) in candidates.enumerated() {
            if offset.isMultiple(of: 16), shouldCancel() {
                return nil
            }
            let url = URL(fileURLWithPath: candidate.record.path)
            guard case let .record(materialized) = retryingFileSystemRecordLookup(
                for: url,
                volumeNameCache: volumeNameCache
            ) else {
                continue
            }
            let record = materialized.record
            guard
                request.includeHidden || !record.isHidden,
                let explanation = FuzzyMatcher.explain(record: record, parsedQuery: parsedQuery)
            else {
                continue
            }
            pendingResults.append(SearchResult(
                record: record,
                score: explanation.score,
                match: explanation,
                rootPath: candidate.rootPath
            ))
        }

        guard !pendingResults.isEmpty else { return response }
        var resultsByPath = Dictionary(uniqueKeysWithValues: response.results.map { ($0.record.path, $0) })
        var addedResultCount = 0
        for result in pendingResults {
            if resultsByPath.updateValue(result, forKey: result.record.path) == nil {
                addedResultCount += 1
            }
        }
        var results = Array(resultsByPath.values)
        Self.sortAndLimit(&results, request: request, maxResults: maxResults)

        return Self.responseByMergingRefreshResults(
            response,
            results: results,
            totalMatches: response.totalMatches + addedResultCount,
            additionalCandidateCount: pendingExactPaths.count,
            additionalScanCount: pendingExactPaths.count
        )
    }

    private static func pendingRefreshSearchCandidate(path: String) -> FileRecord {
        let name = (path as NSString).lastPathComponent
        return FileRecord(
            id: FileRecord.stableID(for: path),
            path: path,
            name: name,
            directoryPath: (path as NSString).deletingLastPathComponent,
            fileExtension: (name as NSString).pathExtension.lowercased(),
            sizeBytes: 0,
            modifiedTime: 0,
            createdTime: nil,
            isDirectory: false,
            isHidden: FileRecord.pathIsHidden(path),
            volumeName: "",
            normalizedName: FuzzyMatcher.normalize(name),
            normalizedPath: FuzzyMatcher.normalize(path)
        )
    }

    private func searchComposite(
        _ request: SearchRequest,
        maxResults: Int,
        state: CompositeSearchState,
        snapshotRevision: UInt64,
        pendingExactPaths: [String],
        rootPaths: [String],
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        let started = Date()
        let metricPhase = request.mode.metricPhase
        recordSearchStarted(phase: metricPhase)
        var didComplete = false
        defer {
            if !didComplete {
                recordSearchCancelled(phase: metricPhase, elapsed: Date().timeIntervalSince(started))
            }
        }

        let boundedMaxResults = max(maxResults, 0)
        let parsedQuery = FuzzyMatcher.parse(
            request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        func isCurrentCompositeGeneration() -> Bool {
            lock.withLock {
                compositeSearchState === state
                    && searchSnapshotRevision == snapshotRevision
            }
        }

        let segments: [SearchSegment]
        let completeness: SearchCompleteness
        let executionPath: SearchExecutionPath
        switch request.mode {
        case .interactivePreview:
            segments = [state.base]
            completeness = .partial
            executionPath = .indexedBasePreview
        case .complete:
            segments = [state.base] + state.deltaSegments
            completeness = .complete
            executionPath = .compositeIndexed
        }

        var segmentResponses: [SearchResponse] = []
        segmentResponses.reserveCapacity(segments.count)
        var segmentLatencies: [TimeInterval] = []
        segmentLatencies.reserveCapacity(segments.count)
        var baseLatency: TimeInterval = 0
        var deltaLatency: TimeInterval = 0
        for (index, segment) in segments.enumerated() {
            guard !shouldCancel(), isCurrentCompositeGeneration() else { return nil }
            let segmentStarted = Date()
            guard let response = searchSingleSnapshot(
                request,
                maxResults: boundedMaxResults,
                snapshotOverride: segment.snapshot,
                snapshotRevisionOverride: snapshotRevision,
                recordsMetrics: false,
                shouldCancel: shouldCancel
            ) else {
                return nil
            }
            let latency = Date().timeIntervalSince(segmentStarted)
            segmentLatencies.append(latency)
            if index == 0 {
                baseLatency = latency
            } else {
                deltaLatency += latency
            }
            segmentResponses.append(response)
        }

        guard !shouldCancel(), isCurrentCompositeGeneration() else { return nil }
        let mergeStarted = Date()
        var results: [SearchResult] = []
        results.reserveCapacity(boundedMaxResults)
        var resultOffsets = Array(repeating: 0, count: segmentResponses.count)
        while results.count < boundedMaxResults {
            if results.count.isMultiple(of: 64),
               (shouldCancel() || !isCurrentCompositeGeneration()) {
                return nil
            }

            var bestSegment: Int?
            for segmentIndex in segmentResponses.indices {
                let resultIndex = resultOffsets[segmentIndex]
                guard resultIndex < segmentResponses[segmentIndex].results.count else { continue }
                guard let currentBest = bestSegment else {
                    bestSegment = segmentIndex
                    continue
                }
                let bestResultIndex = resultOffsets[currentBest]
                if Self.compare(
                    segmentResponses[segmentIndex].results[resultIndex],
                    segmentResponses[currentBest].results[bestResultIndex],
                    sort: request.sort,
                    queryIsEmpty: parsedQuery.isEmpty
                ) {
                    bestSegment = segmentIndex
                }
            }

            guard let bestSegment else { break }
            results.append(segmentResponses[bestSegment].results[resultOffsets[bestSegment]])
            resultOffsets[bestSegment] += 1
        }

        let totalMatches: Int
        if request.mode == .interactivePreview {
            totalMatches = results.count
        } else if parsedQuery.isEmpty {
            totalMatches = request.includeHidden ? state.liveResultCount : state.liveVisibleCount
        } else {
            totalMatches = segmentResponses.reduce(0) { $0 + $1.totalMatches }
        }

        var indexesUsed = segmentResponses.reduce(into: Set<SearchIndexUse>()) {
            $0.formUnion($1.executionProfile.indexesUsed)
        }
        if state.maskedRowCount > 0 {
            indexesUsed.insert(.rowMask)
        }
        if !state.deltaSegments.isEmpty {
            indexesUsed.insert(.structuralDelta)
        }
        let candidateCount = segmentResponses.reduce(0) {
            $0 + $1.executionProfile.candidateCount
        }
        let scannedRowCount = segmentResponses.reduce(0) {
            $0 + $1.executionProfile.scannedRowCount
        }
        let didFallbackToFullScan = segmentResponses.contains {
            $0.executionProfile.didFallbackToFullScan
        }
        let mergeLatency = Date().timeIntervalSince(mergeStarted)
        let interimElapsed = Date().timeIntervalSince(started)
        var response = SearchResponse(
            results: results,
            totalMatches: totalMatches,
            elapsed: interimElapsed,
            snapshotRevision: snapshotRevision,
            usesIndexedCandidates: segmentResponses.allSatisfy(\.usesIndexedCandidates),
            completeness: completeness,
            executionProfile: SearchExecutionProfile(
                executionPath: executionPath,
                indexesUsed: indexesUsed,
                candidateCount: candidateCount,
                scannedRowCount: scannedRowCount,
                didFallbackToFullScan: didFallbackToFullScan,
                elapsed: interimElapsed
            )
        )

        if request.mode == .complete {
            guard let refreshed = mergingPendingExactRefreshes(
                into: response,
                pendingExactPaths: pendingExactPaths,
                currentSnapshot: state.logicalSnapshot,
                rootPaths: rootPaths,
                request: request,
                parsedQuery: parsedQuery,
                maxResults: boundedMaxResults,
                shouldCancel: shouldCancel
            ) else {
                return nil
            }
            response = refreshed
        }

        guard !shouldCancel(), isCurrentCompositeGeneration() else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        let finalProfile = response.executionProfile
        let completed = SearchResponse(
            results: response.results,
            totalMatches: response.totalMatches,
            elapsed: elapsed,
            snapshotRevision: snapshotRevision,
            usesIndexedCandidates: response.usesIndexedCandidates,
            completeness: completeness,
            executionProfile: SearchExecutionProfile(
                executionPath: executionPath,
                indexesUsed: finalProfile.indexesUsed,
                candidateCount: finalProfile.candidateCount,
                scannedRowCount: finalProfile.scannedRowCount,
                didFallbackToFullScan: finalProfile.didFallbackToFullScan,
                elapsed: elapsed
            )
        )
        var diagnosticFields: [String: DiagnosticLogFieldValue] = [
            "segmentCount": .publicInt(segments.count),
            "deltaSegmentCount": .publicInt(request.mode == .complete ? state.deltaSegments.count : 0),
            "maskedRowCount": .publicInt(state.maskedRowCount),
            "baseLatencySeconds": .publicDouble(baseLatency),
            "deltaLatencySeconds": .publicDouble(deltaLatency),
            "mergeLatencySeconds": .publicDouble(mergeLatency),
            "completeness": .publicString(completeness == .complete ? "complete" : "partial")
        ]
        for (index, latency) in segmentLatencies.enumerated() {
            diagnosticFields["segment\(index)LatencySeconds"] = .publicDouble(latency)
        }
        DiagnosticLogger.shared.log(
            category: "search",
            event: "search.compositeExecuted",
            fields: diagnosticFields
        )
        didComplete = true
        recordSearchCompleted(completed.executionProfile, phase: metricPhase)
        return completed
    }

    public func search(
        _ request: SearchRequest,
        maxResults: Int = 2_000,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        let compositeData = lock.withLock {
            (
                state: compositeSearchState,
                revision: searchSnapshotRevision,
                pendingExactPaths: pendingRefreshPaths.values.compactMap {
                    $0.recursivelyScansDirectory ? nil : $0.path
                },
                rootPaths: roots
            )
        }
        if let state = compositeData.state {
            return searchComposite(
                request,
                maxResults: maxResults,
                state: state,
                snapshotRevision: compositeData.revision,
                pendingExactPaths: compositeData.pendingExactPaths,
                rootPaths: compositeData.rootPaths,
                shouldCancel: shouldCancel
            )
        }
        return searchSingleSnapshot(request, maxResults: maxResults, shouldCancel: shouldCancel)
    }

    private func searchSingleSnapshot(
        _ request: SearchRequest,
        maxResults: Int,
        snapshotOverride: SearchSnapshot? = nil,
        snapshotRevisionOverride: UInt64? = nil,
        recordsMetrics: Bool = true,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        let started = Date()
        let metricPhase = request.mode.metricPhase
        if recordsMetrics {
            recordSearchStarted(phase: metricPhase)
        }
        var didCompleteSearch = false

        let trimmedQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedQuery = FuzzyMatcher.parse(trimmedQuery)
        let boundedMaxResults = max(maxResults, 0)

        let snapshotData = lock.withLock {
            if let snapshotOverride {
                return (
                    snapshot: snapshotOverride,
                    currentSnapshot: snapshotOverride,
                    pendingExactPaths: [String](),
                    rootPaths: [String](),
                    revision: snapshotRevisionOverride ?? searchSnapshotRevision,
                    optimizedSortColumns: optimizedSortColumns,
                    canPromoteSortedOrder: false,
                    hasDeferredOptimization: false,
                    isRefreshActive: false
                )
            }
            let currentSnapshot = searchSnapshot
            let fallbackSnapshot = optimizedSearchFallbackSnapshot
            let shouldUseOptimizedFallback = !trimmedQuery.isEmpty
                && request.mode == .interactivePreview
                && !(currentSnapshot.store is OverlayRecordStore)
                && !currentSnapshot.isOptimizedForSearch
                && fallbackSnapshot?.isOptimizedForSearch == true
                && (fallbackSnapshot?.resultCount ?? 0) > 0
            return (
                snapshot: shouldUseOptimizedFallback ? (fallbackSnapshot ?? currentSnapshot) : currentSnapshot,
                currentSnapshot: currentSnapshot,
                pendingExactPaths: pendingRefreshPaths.values.compactMap {
                    $0.recursivelyScansDirectory ? nil : $0.path
                },
                rootPaths: roots,
                revision: searchSnapshotRevision,
                optimizedSortColumns: optimizedSortColumns,
                canPromoteSortedOrder: !indexing && !reconciling && !updating && !isRefreshDrainScheduled && pendingRefreshPaths.isEmpty,
                hasDeferredOptimization: deferredOptimizationReason != nil,
                isRefreshActive: reconciling || updating || isRefreshDrainScheduled || !pendingRefreshPaths.isEmpty
            )
        }
        var snapshot = snapshotData.snapshot
        var snapshotRevision = snapshotData.revision

        func finish(_ response: SearchResponse) -> SearchResponse? {
            guard !shouldCancel() else { return nil }
            guard let mergedResponse = mergingPendingExactRefreshes(
                into: response,
                pendingExactPaths: snapshotData.pendingExactPaths,
                currentSnapshot: snapshotData.currentSnapshot,
                rootPaths: snapshotData.rootPaths,
                request: request,
                parsedQuery: parsedQuery,
                maxResults: boundedMaxResults,
                shouldCancel: shouldCancel
            ) else {
                return nil
            }
            guard !shouldCancel() else { return nil }

            let completedElapsed = Date().timeIntervalSince(started)
            let profile = mergedResponse.executionProfile
            let completedResponse = SearchResponse(
                results: mergedResponse.results,
                totalMatches: mergedResponse.totalMatches,
                elapsed: completedElapsed,
                snapshotRevision: mergedResponse.snapshotRevision,
                usesIndexedCandidates: mergedResponse.usesIndexedCandidates,
                completeness: request.mode == .interactivePreview ? .partial : .complete,
                executionProfile: SearchExecutionProfile(
                    executionPath: profile.executionPath,
                    indexesUsed: profile.indexesUsed,
                    candidateCount: profile.candidateCount,
                    scannedRowCount: profile.scannedRowCount,
                    didFallbackToFullScan: profile.didFallbackToFullScan,
                    wasCancelled: profile.wasCancelled,
                    wasStaleRetry: profile.wasStaleRetry,
                    elapsed: completedElapsed
                )
            )
            didCompleteSearch = true
            if recordsMetrics {
                recordSearchCompleted(completedResponse.executionProfile, phase: metricPhase)
            }
            return completedResponse
        }

        defer {
            if recordsMetrics, !didCompleteSearch {
                recordSearchCancelled(phase: metricPhase, elapsed: Date().timeIntervalSince(started))
            }
        }

        guard !shouldCancel() else { return nil }

        let usesDegradedSearch = request.mode == .interactivePreview
            && Self.shouldUseDegradedSearch(
                snapshot: snapshot,
                isRefreshActive: snapshotData.isRefreshActive
            )
        let exactEmptyQuerySortLimit = lock.withLock { exactEmptyQuerySortLimitOverride }
            ?? Self.exactEmptyQuerySortLimit

        if Self.shouldPromoteSortedOrderForEmptyQuery(
            snapshot: snapshot,
            request: request,
            parsedQuery: parsedQuery,
            maxResults: boundedMaxResults,
            canPromoteSortedOrder: snapshotData.canPromoteSortedOrder
                && !snapshotData.hasDeferredOptimization
                && !usesDegradedSearch,
            optimizedSortColumns: snapshotData.optimizedSortColumns
        ) {
            let promotedSnapshot: SearchSnapshot
            switch request.sort.column {
            case .name:
                promotedSnapshot = snapshot.addingModifiedSortOrder()
            case .modified, .relevance:
                promotedSnapshot = snapshot.addingModifiedSortOrderOnly()
            case .path, .created, .size, .fileExtension, .kind, .volume, .root:
                promotedSnapshot = snapshot.addingOptimizedSortOrder(
                    for: request.sort.column,
                    optimizedSortColumns: snapshotData.optimizedSortColumns
                )
            }
            let installedRevision = lock.withLock { () -> UInt64? in
                guard searchSnapshot === snapshot, searchSnapshotRevision == snapshotRevision else {
                    return nil
                }

                searchSnapshot = promotedSnapshot
                advanceSearchSnapshotRevisionPreservingDurabilityWithoutLock()
                lastUpdated = Date()
                if promotedSnapshot.isOptimizedForSearch {
                    optimizedCount = promotedSnapshot.resultCount
                }
                return searchSnapshotRevision
            }

            if let installedRevision {
                snapshot = promotedSnapshot
                snapshotRevision = installedRevision
                publishStats()
            } else {
                let refreshedSnapshotData = lock.withLock {
                    (snapshot: searchSnapshot, revision: searchSnapshotRevision)
                }
                snapshot = refreshedSnapshotData.snapshot
                snapshotRevision = refreshedSnapshotData.revision
            }
        }

        guard !shouldCancel() else { return nil }

        var matches: [SearchMatch] = []
        matches.reserveCapacity(min(snapshot.count, boundedMaxResults))
        let trimThreshold = boundedMaxResults > 0 ? boundedMaxResults * 5 : 0
        var total = 0
        var shouldSortMatches = true
        var emptyQueryScannedRowCount: Int?
        var fallbackScannedRowCount: Int?

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
                includeHidden: request.includeHidden,
                optimizedSortColumns: snapshotData.optimizedSortColumns
            ) {
                let knownTotal: Int?
                if request.includeHidden {
                    knownTotal = snapshot.resultCount
                } else if let visibleCount = snapshot.visibleResultCount {
                    knownTotal = visibleCount
                } else if request.sort.column == .modified || request.sort.column == .relevance {
                    knownTotal = orderedRecords.count
                } else {
                    knownTotal = nil
                }

                if let knownTotal {
                    total = knownTotal
                    shouldSortMatches = false
                    let targetResultCount = min(boundedMaxResults, knownTotal)
                    var scannedRows = 0

                    if targetResultCount > 0 {
                        for (offset, index) in orderedRecords.enumerated() {
                            if offset.isMultiple(of: 512), shouldCancel() {
                                return nil
                            }

                            scannedRows += 1
                            guard snapshot.store.isResultRow(at: index) else { continue }
                            guard request.includeHidden || snapshot.isVisible(at: index) else { continue }
                            matches.append(SearchMatch(rowID: index, score: 0))
                            if matches.count == targetResultCount {
                                break
                            }
                        }
                    }
                    emptyQueryScannedRowCount = scannedRows
                } else {
                    for (offset, index) in orderedRecords.enumerated() {
                        if offset.isMultiple(of: 512), shouldCancel() {
                            return nil
                        }
                        appendMatch(rowID: index, score: 0)
                    }
                }
            } else if snapshot.count > exactEmptyQuerySortLimit, boundedMaxResults > 0 {
                shouldSortMatches = false
                let visibleResultCount = snapshot.visibleResultCount
                let canStopAtResultLimit = request.includeHidden || visibleResultCount != nil
                var matchedVisibleCount = 0
                var scannedRows = 0
                for index in 0..<snapshot.count {
                    if index.isMultiple(of: 512), shouldCancel() {
                        return nil
                    }

                    scannedRows += 1
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

                total = request.includeHidden ? snapshot.resultCount : (visibleResultCount ?? matchedVisibleCount)
                emptyQueryScannedRowCount = scannedRows
            } else {
                for index in 0..<snapshot.count {
                    if index.isMultiple(of: 512), shouldCancel() {
                        return nil
                    }
                    appendMatch(rowID: index, score: 0)
                }
            }
        } else {
            if usesDegradedSearch, !snapshot.isOptimizedForSearch {
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

                if let degradedResponse = Self.degradedSearch(
                    snapshot: snapshot,
                    request: request,
                    parsedQuery: parsedQuery,
                    maxResults: boundedMaxResults,
                    started: started,
                    snapshotRevision: snapshotRevision,
                    shouldCancel: shouldCancel
                ) {
                    return finish(degradedResponse)
                }
            }

            if let fastResponse = Self.fastExactExtensionSearch(
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

            if let sortedResponse = Self.optimizedSortedUnifiedSearch(
                snapshot: snapshot,
                request: request,
                parsedQuery: parsedQuery,
                maxResults: boundedMaxResults,
                started: started,
                snapshotRevision: snapshotRevision,
                optimizedSortColumns: snapshotData.optimizedSortColumns,
                shouldCancel: shouldCancel
            ) {
                return finish(sortedResponse)
            }

            if let fastResponse = Self.fastModifiedInteractivePreviewSearch(
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

            if let fastResponse = Self.fastModifiedNameOnlyInteractivePreviewScan(
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

            if let fastResponse = Self.fastRelevanceInteractivePreviewSearch(
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

            if let fastResponse = Self.fastNameCandidateInteractivePreviewSearch(
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

            if let fastResponse = Self.fastNameInteractivePreviewSearch(
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

            if let fastResponse = Self.fastComponentNameSortedSearch(
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

            if let fastResponse = Self.fastExactExtensionSearch(
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

            if let sortedNamePreviewResponse = Self.optimizedSortedNamePreviewSearch(
                snapshot: snapshot,
                request: request,
                parsedQuery: parsedQuery,
                maxResults: boundedMaxResults,
                started: started,
                snapshotRevision: snapshotRevision,
                optimizedSortColumns: snapshotData.optimizedSortColumns,
                shouldCancel: shouldCancel
            ) {
                return finish(sortedNamePreviewResponse)
            }

            if let sortedPreviewResponse = Self.optimizedSortedCandidateSearch(
                snapshot: snapshot,
                request: request,
                parsedQuery: parsedQuery,
                maxResults: boundedMaxResults,
                started: started,
                snapshotRevision: snapshotRevision,
                optimizedSortColumns: snapshotData.optimizedSortColumns,
                shouldCancel: shouldCancel
            ) {
                return finish(sortedPreviewResponse)
            }

            if Self.shouldUseBoundedPreviewCandidateSearch(request: request),
               let cheapIndexedResponse = Self.cheapIndexedCandidateSearch(
                snapshot: snapshot,
                request: request,
                parsedQuery: parsedQuery,
                maxResults: boundedMaxResults,
                started: started,
                snapshotRevision: snapshotRevision,
                shouldCancel: shouldCancel
               ) {
                return finish(cheapIndexedResponse)
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

            if let cheapIndexedResponse = Self.cheapIndexedCandidateSearch(
                snapshot: snapshot,
                request: request,
                parsedQuery: parsedQuery,
                maxResults: boundedMaxResults,
                started: started,
                snapshotRevision: snapshotRevision,
                shouldCancel: shouldCancel
            ) {
                return finish(cheapIndexedResponse)
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

            if usesDegradedSearch, let degradedResponse = Self.degradedSearch(
                snapshot: snapshot,
                request: request,
                parsedQuery: parsedQuery,
                maxResults: boundedMaxResults,
                started: started,
                snapshotRevision: snapshotRevision,
                shouldCancel: shouldCancel
            ) {
                return finish(degradedResponse)
            }

            let fallbackScanLimit = Self.fallbackScanLimit(
                for: request,
                maxResults: boundedMaxResults,
                snapshotCount: snapshot.count
            )
            let scannedRows = min(snapshot.count, fallbackScanLimit)
            fallbackScannedRowCount = scannedRows
            lock.withLock {
                fallbackScanCount &+= 1
                scannedRowCount &+= UInt64(scannedRows)
            }
            for index in 0..<scannedRows {
                if index.isMultiple(of: 64), shouldCancel() {
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
            var indexesUsed: Set<SearchIndexUse> = request.sort.column == .modified || request.sort.column == .relevance
                ? [.modifiedOrder]
                : [.sortOrder]
            if !request.includeHidden {
                indexesUsed.insert(.visibleBitset)
            }
            profile = SearchExecutionProfile(
                executionPath: .emptyQuerySortedOrder,
                indexesUsed: indexesUsed,
                candidateCount: total,
                scannedRowCount: emptyQueryScannedRowCount ?? min(snapshot.count, total),
                elapsed: elapsed
            )
        } else {
            profile = SearchExecutionProfile(
                executionPath: .fullFallbackScan,
                scannedRowCount: fallbackScannedRowCount ?? snapshot.count,
                didFallbackToFullScan: true,
                elapsed: elapsed
            )
        }

        return finish(SearchResponse(
            results: Self.materialize(matches, from: snapshot, shouldCancel: shouldCancel),
            totalMatches: total,
            elapsed: elapsed,
            snapshotRevision: snapshotRevision,
            usesIndexedCandidates: parsedQuery.isEmpty,
            executionProfile: profile
        ))
    }

    private static func shouldUseBoundedPreviewCandidateSearch(request: SearchRequest) -> Bool {
        guard request.mode == .interactivePreview else { return false }
        switch request.sort.column {
        case .path, .created, .size, .fileExtension, .kind, .volume, .root:
            return true
        case .relevance, .name, .modified:
            return false
        }
    }

    private static func usesAdditionalSortOrder(_ column: SortColumn) -> Bool {
        switch column {
        case .path, .created, .size, .fileExtension, .kind, .volume, .root:
            return true
        case .relevance, .name, .modified:
            return false
        }
    }

    private static func optimizedSortedUnifiedSearch(
        snapshot: SearchSnapshot,
        request: SearchRequest,
        parsedQuery: FuzzyMatcher.ParsedQuery,
        maxResults: Int,
        started: Date,
        snapshotRevision: UInt64,
        optimizedSortColumns: Set<SortColumn>,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        guard
            maxResults > 0,
            !parsedQuery.isEmpty,
            usesAdditionalSortOrder(request.sort.column)
                || (request.sort.column == .modified && request.mode == .interactivePreview)
        else {
            return nil
        }

        let simpleNameQuery = request.mode == .interactivePreview
            ? simpleNamePreviewQuery(parsedQuery)
            : nil

        let candidateIndices: [Int32]
        var indexesUsed: Set<SearchIndexUse>
        if let simpleNameQuery {
            guard let nameCandidates = snapshot.candidateNameIndices(
                containing: Array(simpleNameQuery.token.utf8),
                shouldCancel: shouldCancel
            ) else {
                return nil
            }
            candidateIndices = nameCandidates
            indexesUsed = [.nameGrams]
        } else {
            guard let candidates = Self.candidateIndices(
                snapshot: snapshot,
                parsedQuery: parsedQuery,
                shouldCancel: shouldCancel
            ) else {
                return nil
            }
            candidateIndices = candidates
            indexesUsed = indexUses(for: parsedQuery)
        }

        indexesUsed.insert(request.sort.column == .modified ? .modifiedOrder : .sortOrder)
        if !request.includeHidden {
            indexesUsed.insert(.visibleBitset)
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
                    executionPath: .optimizedSortedFastPath,
                    indexesUsed: indexesUsed,
                    candidateCount: 0,
                    scannedRowCount: 0,
                    elapsed: elapsed
                )
            )
        }

        if request.mode == .interactivePreview,
           candidateIndices.count > max(1_000, maxResults * 50),
           let orderedResponse = optimizedSortedOrderScanSearch(
               snapshot: snapshot,
               request: request,
               parsedQuery: parsedQuery,
               simpleNameQuery: simpleNameQuery,
               candidateIndices: candidateIndices,
               indexesUsed: indexesUsed,
               maxResults: maxResults,
               started: started,
               snapshotRevision: snapshotRevision,
               optimizedSortColumns: optimizedSortColumns,
               shouldCancel: shouldCancel
           ) {
            return orderedResponse
        }

        guard let rankMap = snapshot.sortRankMap(
            for: request.sort,
            includeHidden: request.includeHidden,
            optimizedSortColumns: optimizedSortColumns
        ) else {
            return nil
        }

        var matches: [RankedSearchMatch] = []
        matches.reserveCapacity(min(maxResults, candidateIndices.count))
        let trimThreshold = max(maxResults * 8, 256)
        var total = 0
        var scannedRows = 0
        var pathContainsCache: [Int: Bool] = [:]

        func sortAndLimitMatches() {
            matches.sort { lhs, rhs in
                lhs.rank < rhs.rank
            }
            if matches.count > maxResults {
                matches.removeSubrange(maxResults..<matches.count)
            }
        }

        for (offset, candidate) in candidateIndices.enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }

            let rowID = Int(candidate)
            guard rowID >= 0, rowID < snapshot.count, rowID < rankMap.count else { continue }
            let rank = rankMap[rowID]
            guard rank >= 0 else { continue }
            scannedRows += 1
            guard snapshot.store.isResultRow(at: rowID) else { continue }
            guard request.includeHidden || snapshot.isVisible(at: rowID) else { continue }

            let explanation: MatchExplanation?
            if let simpleNameQuery {
                explanation = cheapIndexedNameExplanation(
                    snapshot: snapshot,
                    rowID: rowID,
                    token: simpleNameQuery.token,
                    mode: simpleNameQuery.mode
                )
            } else if request.mode == .interactivePreview {
                explanation = cheapDegradedExplanation(
                    snapshot: snapshot,
                    rowID: rowID,
                    parsedQuery: parsedQuery,
                    pathContainsCache: &pathContainsCache
                )
            } else {
                explanation = FuzzyMatcher.explain(record: snapshot.view(at: rowID), parsedQuery: parsedQuery)
            }

            guard let explanation else { continue }
            total += 1
            matches.append(RankedSearchMatch(
                rank: rank,
                match: SearchMatch(rowID: rowID, score: explanation.score, match: explanation)
            ))
            if matches.count > trimThreshold {
                sortAndLimitMatches()
            }
        }

        guard !shouldCancel() else { return nil }
        sortAndLimitMatches()

        let elapsed = Date().timeIntervalSince(started)
        return SearchResponse(
            results: materialize(matches.map(\.match), from: snapshot, shouldCancel: shouldCancel),
            totalMatches: total,
            elapsed: elapsed,
            snapshotRevision: snapshotRevision,
            usesIndexedCandidates: true,
            executionProfile: SearchExecutionProfile(
                executionPath: .optimizedSortedFastPath,
                indexesUsed: indexesUsed,
                candidateCount: candidateIndices.count,
                scannedRowCount: scannedRows,
                elapsed: elapsed
            )
        )
    }

    private static func optimizedSortedOrderScanSearch(
        snapshot: SearchSnapshot,
        request: SearchRequest,
        parsedQuery: FuzzyMatcher.ParsedQuery,
        simpleNameQuery: (token: String, mode: FuzzyMatcher.MatchMode)?,
        candidateIndices: [Int32],
        indexesUsed: Set<SearchIndexUse>,
        maxResults: Int,
        started: Date,
        snapshotRevision: UInt64,
        optimizedSortColumns: Set<SortColumn>,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        var included = Array(repeating: UInt8(0), count: snapshot.count)
        var markedCandidateCount = 0
        for (offset, candidate) in candidateIndices.enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }

            let rowID = Int(candidate)
            guard rowID >= 0, rowID < included.count else { continue }
            guard included[rowID] == 0 else { continue }
            guard snapshot.store.isResultRow(at: rowID) else { continue }
            guard request.includeHidden || snapshot.isVisible(at: rowID) else { continue }
            included[rowID] = 1
            markedCandidateCount += 1
        }

        guard markedCandidateCount > 0 else {
            let elapsed = Date().timeIntervalSince(started)
            return SearchResponse(
                results: [],
                totalMatches: 0,
                elapsed: elapsed,
                snapshotRevision: snapshotRevision,
                usesIndexedCandidates: true,
                executionProfile: SearchExecutionProfile(
                    executionPath: .optimizedSortedFastPath,
                    indexesUsed: indexesUsed,
                    candidateCount: candidateIndices.count,
                    scannedRowCount: 0,
                    elapsed: elapsed
                )
            )
        }

        var pathContainsCache: [Int: Bool] = [:]
        let scanLimit = max(Self.previewOrderedCandidateScanLimit, maxResults * 500)
        guard let selected = orderedCandidatePreviewSelection(
            snapshot: snapshot,
            request: request,
            maxResults: maxResults,
            total: markedCandidateCount,
            scanLimit: scanLimit,
            requiresFilledResults: true,
            optimizedSortColumns: optimizedSortColumns,
            shouldCancel: shouldCancel,
            candidateContains: { rowID in
                included[rowID] != 0
            },
            explanation: { rowID in
                if let simpleNameQuery {
                    return cheapIndexedNameExplanation(
                        snapshot: snapshot,
                        rowID: rowID,
                        token: simpleNameQuery.token,
                        mode: simpleNameQuery.mode
                    )
                }

                return cheapDegradedExplanation(
                    snapshot: snapshot,
                    rowID: rowID,
                    parsedQuery: parsedQuery,
                    pathContainsCache: &pathContainsCache
                )
            }
        ) else {
            return nil
        }

        let elapsed = Date().timeIntervalSince(started)
        return SearchResponse(
            results: materialize(selected.matches, from: snapshot, shouldCancel: shouldCancel),
            totalMatches: selected.matches.count,
            elapsed: elapsed,
            snapshotRevision: snapshotRevision,
            usesIndexedCandidates: true,
            executionProfile: SearchExecutionProfile(
                executionPath: .optimizedSortedFastPath,
                indexesUsed: indexesUsed,
                candidateCount: candidateIndices.count,
                scannedRowCount: selected.scannedRowCount,
                elapsed: elapsed
            )
        )
    }

    private static func simpleNamePreviewQuery(
        _ parsedQuery: FuzzyMatcher.ParsedQuery
    ) -> (token: String, mode: FuzzyMatcher.MatchMode)? {
        guard
            parsedQuery.negative.isEmpty,
            parsedQuery.positive.count == 1,
            let clause = parsedQuery.positive.first,
            clause.alternatives.count == 1,
            let part = clause.alternatives.first,
            case .text(let field, let pattern, let mode) = part,
            field != .path,
            mode == .fuzzy || mode == .exact,
            !pattern.token.isEmpty,
            !tokenContainsPathSeparator(pattern.token)
        else {
            return nil
        }

        return (pattern.token, mode)
    }

    private static func optimizedSortedNamePreviewSearch(
        snapshot: SearchSnapshot,
        request: SearchRequest,
        parsedQuery: FuzzyMatcher.ParsedQuery,
        maxResults: Int,
        started: Date,
        snapshotRevision: UInt64,
        optimizedSortColumns: Set<SortColumn>,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        guard
            request.mode == .interactivePreview,
            maxResults > 0,
            !parsedQuery.isEmpty,
            parsedQuery.negative.isEmpty,
            parsedQuery.positive.count == 1,
            let clause = parsedQuery.positive.first,
            clause.alternatives.count == 1,
            let part = clause.alternatives.first,
            case .text(let field, let pattern, let mode) = part,
            field != .path,
            mode == .fuzzy || mode == .exact,
            !pattern.token.isEmpty,
            !tokenContainsPathSeparator(pattern.token),
            let nameCandidates = snapshot.candidateNameIndices(
                containing: Array(pattern.token.utf8),
                shouldCancel: shouldCancel
            )
        else {
            return nil
        }

        var indexesUsed: Set<SearchIndexUse> = [.nameGrams]
        indexesUsed.insert(request.sort.column == .modified ? .modifiedOrder : .sortOrder)
        if !request.includeHidden {
            indexesUsed.insert(.visibleBitset)
        }

        if nameCandidates.isEmpty {
            let elapsed = Date().timeIntervalSince(started)
            return SearchResponse(
                results: [],
                totalMatches: 0,
                elapsed: elapsed,
                snapshotRevision: snapshotRevision,
                usesIndexedCandidates: true,
                executionProfile: SearchExecutionProfile(
                    executionPath: .optimizedSortedFastPath,
                    indexesUsed: indexesUsed,
                    candidateCount: 0,
                    scannedRowCount: 0,
                    elapsed: elapsed
                )
            )
        }

        var nameRows = Array(repeating: UInt8(0), count: snapshot.count)
        var visibleNameCandidateCount = 0
        for (offset, candidate) in nameCandidates.enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }

            let rowID = Int(candidate)
            guard rowID >= 0, rowID < snapshot.count else { continue }
            guard snapshot.store.isResultRow(at: rowID) else { continue }
            guard request.includeHidden || snapshot.isVisible(at: rowID) else { continue }
            nameRows[rowID] = 1
            visibleNameCandidateCount += 1
        }

        guard visibleNameCandidateCount > 0 else {
            let elapsed = Date().timeIntervalSince(started)
            return SearchResponse(
                results: [],
                totalMatches: 0,
                elapsed: elapsed,
                snapshotRevision: snapshotRevision,
                usesIndexedCandidates: true,
                executionProfile: SearchExecutionProfile(
                    executionPath: .optimizedSortedFastPath,
                    indexesUsed: indexesUsed,
                    candidateCount: nameCandidates.count,
                    scannedRowCount: 0,
                    elapsed: elapsed
                )
            )
        }

        guard let selected = orderedCandidatePreviewSelection(
            snapshot: snapshot,
            request: request,
            maxResults: maxResults,
            total: visibleNameCandidateCount,
            optimizedSortColumns: optimizedSortColumns,
            shouldCancel: shouldCancel,
            candidateContains: { rowID in
                nameRows[rowID] != 0
            },
            explanation: { rowID in
                cheapIndexedNameExplanation(
                    snapshot: snapshot,
                    rowID: rowID,
                    token: pattern.token,
                    mode: mode
                )
            }
        ) else {
            return nil
        }

        let elapsed = Date().timeIntervalSince(started)
        return SearchResponse(
            results: materialize(selected.matches, from: snapshot, shouldCancel: shouldCancel),
            totalMatches: visibleNameCandidateCount,
            elapsed: elapsed,
            snapshotRevision: snapshotRevision,
            usesIndexedCandidates: true,
            executionProfile: SearchExecutionProfile(
                executionPath: .optimizedSortedFastPath,
                indexesUsed: indexesUsed,
                candidateCount: nameCandidates.count,
                scannedRowCount: selected.scannedRowCount,
                elapsed: elapsed
            )
        )
    }

    private static func optimizedSortedCandidateSearch(
        snapshot: SearchSnapshot,
        request: SearchRequest,
        parsedQuery: FuzzyMatcher.ParsedQuery,
        maxResults: Int,
        started: Date,
        snapshotRevision: UInt64,
        optimizedSortColumns: Set<SortColumn>,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        guard
            maxResults > 0,
            !parsedQuery.isEmpty,
            request.mode == .interactivePreview || usesAdditionalSortOrder(request.sort.column),
            let orderedRows = snapshot.orderedIndices(
                for: request.sort,
                queryIsEmpty: false,
                includeHidden: request.includeHidden,
                optimizedSortColumns: optimizedSortColumns
            ),
            let candidateIndices = candidateIndices(
                snapshot: snapshot,
                parsedQuery: parsedQuery,
                shouldCancel: shouldCancel
            )
        else {
            return nil
        }

        if request.mode == .interactivePreview, candidateIndices.count <= max(1_000, maxResults * 50) {
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
                    executionPath: executionPath(forIndexedCandidateQuery: parsedQuery),
                    indexesUsed: indexUses(for: parsedQuery),
                    candidateCount: 0,
                    scannedRowCount: 0,
                    elapsed: elapsed
                )
            )
        }

        var included = Array(repeating: UInt8(0), count: snapshot.count)
        var markedCandidateCount = 0
        for (offset, candidate) in candidateIndices.enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }

            let rowID = Int(candidate)
            guard rowID >= 0, rowID < snapshot.count else { continue }
            guard included[rowID] == 0 else { continue }
            guard snapshot.store.isResultRow(at: rowID) else { continue }
            guard request.includeHidden || snapshot.isVisible(at: rowID) else { continue }
            included[rowID] = 1
            markedCandidateCount += 1
        }

        guard markedCandidateCount > 0 else {
            let elapsed = Date().timeIntervalSince(started)
            return SearchResponse(
                results: [],
                totalMatches: 0,
                elapsed: elapsed,
                snapshotRevision: snapshotRevision,
                usesIndexedCandidates: true,
                executionProfile: SearchExecutionProfile(
                    executionPath: .optimizedSortedFastPath,
                    indexesUsed: indexUses(for: parsedQuery).union([.sortOrder]),
                    candidateCount: candidateIndices.count,
                    scannedRowCount: 0,
                    elapsed: elapsed
                )
            )
        }

        var matches: [SearchMatch] = []
        matches.reserveCapacity(min(maxResults, markedCandidateCount))
        var pathContainsCache: [Int: Bool] = [:]
        var scannedRows = 0
        var totalMatches = 0
        let scanLimit: Int
        switch request.mode {
        case .interactivePreview:
            scanLimit = min(orderedRows.count, max(Self.previewOrderedCandidateScanLimit, maxResults * 500))
        case .complete:
            scanLimit = orderedRows.count
        }

        for (offset, rowID) in orderedRows.prefix(scanLimit).enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }

            scannedRows += 1
            guard rowID >= 0, rowID < snapshot.count else { continue }
            guard included[rowID] != 0 else { continue }
            guard let explanation = cheapDegradedExplanation(
                snapshot: snapshot,
                rowID: rowID,
                parsedQuery: parsedQuery,
                pathContainsCache: &pathContainsCache
            ) else {
                continue
            }

            totalMatches += 1
            if matches.count < maxResults {
                matches.append(SearchMatch(rowID: rowID, score: explanation.score, match: explanation))
            }
            if request.mode == .interactivePreview, matches.count == maxResults {
                break
            }
        }

        guard !shouldCancel() else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        var indexesUsed = indexUses(for: parsedQuery)
        indexesUsed.insert(request.sort.column == .modified ? .modifiedOrder : .sortOrder)
        if !request.includeHidden {
            indexesUsed.insert(.visibleBitset)
        }
        return SearchResponse(
            results: materialize(matches, from: snapshot, shouldCancel: shouldCancel),
            totalMatches: request.mode == .interactivePreview ? markedCandidateCount : totalMatches,
            elapsed: elapsed,
            snapshotRevision: snapshotRevision,
            usesIndexedCandidates: true,
            executionProfile: SearchExecutionProfile(
                executionPath: .optimizedSortedFastPath,
                indexesUsed: indexesUsed,
                candidateCount: candidateIndices.count,
                scannedRowCount: scannedRows,
                elapsed: elapsed
            )
        )
    }

    private static func fallbackScanLimit(for request: SearchRequest, maxResults: Int, snapshotCount: Int) -> Int {
        switch request.mode {
        case .interactivePreview:
            return min(snapshotCount, max(Self.previewIndexedCandidateScanLimit, maxResults * 500))
        case .complete:
            return snapshotCount
        }
    }

    private static func cheapIndexedCandidateSearch(
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

        let indexesUsed = indexUses(for: parsedQuery)
        guard request.mode == .interactivePreview else {
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
                    executionPath: executionPath(forIndexedCandidateQuery: parsedQuery),
                    indexesUsed: indexesUsed,
                    candidateCount: 0,
                    scannedRowCount: 0,
                    elapsed: elapsed
                )
            )
        }

        let scanLimit = min(candidateIndices.count, max(Self.previewIndexedCandidateScanLimit, maxResults * 500))

        var matches: [SearchMatch] = []
        matches.reserveCapacity(min(maxResults, scanLimit))
        let trimThreshold = maxResults > 0 ? maxResults * 5 : 0
        var total = 0
        var scannedRows = 0
        var pathContainsCache: [Int: Bool] = [:]

        func sortAndLimitMatches() {
            guard maxResults > 0 else { return }
            matches.sort {
                compare($0, $1, snapshot: snapshot, sort: request.sort, queryIsEmpty: false)
            }
            if matches.count > maxResults {
                matches.removeSubrange(maxResults..<matches.count)
            }
        }

        for (offset, candidate) in candidateIndices.prefix(scanLimit).enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }

            let rowID = Int(candidate)
            guard rowID >= 0, rowID < snapshot.count else { continue }
            scannedRows += 1
            guard snapshot.store.isResultRow(at: rowID) else { continue }
            guard request.includeHidden || snapshot.isVisible(at: rowID) else { continue }
            guard let explanation = cheapDegradedExplanation(
                snapshot: snapshot,
                rowID: rowID,
                parsedQuery: parsedQuery,
                pathContainsCache: &pathContainsCache
            ) else {
                continue
            }

            total += 1
            guard maxResults > 0 else { continue }
            matches.append(SearchMatch(rowID: rowID, score: explanation.score, match: explanation))
            if matches.count > trimThreshold {
                sortAndLimitMatches()
            }
        }

        guard !shouldCancel() else { return nil }
        sortAndLimitMatches()

        let elapsed = Date().timeIntervalSince(started)
        return SearchResponse(
            results: materialize(matches, from: snapshot, shouldCancel: shouldCancel),
            totalMatches: total,
            elapsed: elapsed,
            snapshotRevision: snapshotRevision,
            usesIndexedCandidates: true,
            executionProfile: SearchExecutionProfile(
                executionPath: executionPath(forIndexedCandidateQuery: parsedQuery),
                indexesUsed: indexesUsed,
                candidateCount: candidateIndices.count,
                scannedRowCount: scannedRows,
                elapsed: elapsed
            )
        )
    }

    private static func degradedSearch(
        snapshot: SearchSnapshot,
        request: SearchRequest,
        parsedQuery: FuzzyMatcher.ParsedQuery,
        maxResults: Int,
        started: Date,
        snapshotRevision: UInt64,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        let scanLimit = min(snapshot.count, Self.degradedSearchMaximumScanLimit)
        var matches: [SearchMatch] = []
        matches.reserveCapacity(min(scanLimit, maxResults))
        let trimThreshold = maxResults > 0 ? maxResults * 5 : 0
        var total = 0
        var scannedRows = 0
        var pathContainsCache: [Int: Bool] = [:]

        func sortAndLimitMatches() {
            guard maxResults > 0 else { return }
            matches.sort {
                Self.compare($0, $1, snapshot: snapshot, sort: request.sort, queryIsEmpty: false)
            }
            if matches.count > maxResults {
                matches.removeSubrange(maxResults..<matches.count)
            }
        }

        for rowID in 0..<scanLimit {
            if rowID.isMultiple(of: 64), shouldCancel() {
                return nil
            }

            scannedRows += 1
            guard snapshot.store.isResultRow(at: rowID) else { continue }
            guard request.includeHidden || snapshot.isVisible(at: rowID) else { continue }
            guard let explanation = cheapDegradedExplanation(
                snapshot: snapshot,
                rowID: rowID,
                parsedQuery: parsedQuery,
                pathContainsCache: &pathContainsCache
            ) else {
                continue
            }

            total += 1
            guard maxResults > 0 else { continue }
            matches.append(SearchMatch(rowID: rowID, score: explanation.score, match: explanation))
            if matches.count > trimThreshold {
                sortAndLimitMatches()
            }
        }

        guard !shouldCancel() else { return nil }
        sortAndLimitMatches()

        let elapsed = Date().timeIntervalSince(started)
        return SearchResponse(
            results: materialize(matches, from: snapshot, shouldCancel: shouldCancel),
            totalMatches: total,
            elapsed: elapsed,
            snapshotRevision: snapshotRevision,
            usesIndexedCandidates: false,
            executionProfile: SearchExecutionProfile(
                executionPath: .fullFallbackScan,
                candidateCount: scanLimit,
                scannedRowCount: scannedRows,
                didFallbackToFullScan: false,
                elapsed: elapsed
            )
        )
    }

    private static func cheapDegradedExplanation(
        snapshot: SearchSnapshot,
        rowID: Int,
        parsedQuery: FuzzyMatcher.ParsedQuery,
        pathContainsCache: inout [Int: Bool]
    ) -> MatchExplanation? {
        guard !parsedQuery.isEmpty else { return nil }

        for negative in parsedQuery.negative {
            if cheapDegradedExplanation(
                snapshot: snapshot,
                rowID: rowID,
                clause: negative,
                pathContainsCache: &pathContainsCache
            ) != nil {
                return nil
            }
        }

        var totalScore = 0
        var spans: [MatchSpan] = []
        var best: MatchExplanation?
        for clause in parsedQuery.positive {
            guard let explanation = cheapDegradedExplanation(
                snapshot: snapshot,
                rowID: rowID,
                clause: clause,
                pathContainsCache: &pathContainsCache
            ) else {
                return nil
            }
            totalScore += explanation.score
            spans.append(contentsOf: explanation.spans)
            if best == nil
                || explanation.quality > best!.quality
                || (explanation.quality == best!.quality && explanation.score > best!.score) {
                best = explanation
            }
        }

        guard let best else { return nil }
        let depthPenalty = min(snapshot.store.path(at: rowID).filter { $0 == "/" }.count * 4, 120)
        let hiddenPenalty = snapshot.store.isHidden(at: rowID) ? 35 : 0
        let finalScore = totalScore - depthPenalty - hiddenPenalty
        return MatchExplanation(
            matchClass: best.matchClass,
            score: finalScore,
            field: best.field,
            reason: parsedQuery.positive.count == 1 ? best.reason : "Matched all query terms",
            spans: spans
        )
    }

    private static func cheapDegradedExplanation(
        snapshot: SearchSnapshot,
        rowID: Int,
        clause: FuzzyMatcher.QueryClause,
        pathContainsCache: inout [Int: Bool]
    ) -> MatchExplanation? {
        var best: MatchExplanation?
        for alternative in clause.alternatives {
            guard let explanation = cheapDegradedExplanation(
                snapshot: snapshot,
                rowID: rowID,
                part: alternative,
                pathContainsCache: &pathContainsCache
            ) else {
                continue
            }
            if best == nil
                || explanation.quality > best!.quality
                || (explanation.quality == best!.quality && explanation.score > best!.score) {
                best = explanation
            }
        }
        return best
    }

    private static func cheapDegradedExplanation(
        snapshot: SearchSnapshot,
        rowID: Int,
        part: FuzzyMatcher.QueryPart,
        pathContainsCache: inout [Int: Bool]
    ) -> MatchExplanation? {
        switch part {
        case .text(let field, let pattern, let mode):
            let token = mode == .wildcard ? cheapWildcardLiteralToken(pattern.token) : pattern.token
            guard !token.isEmpty else { return nil }
            if field != .path,
               let nameExplanation = cheapLiteralNameExplanation(
                   snapshot: snapshot,
                   rowID: rowID,
                   token: token,
                   mode: mode
               ) {
                return nameExplanation
            }
            if field != .name,
               snapshot.store.normalizedPath(at: rowID, contains: token, cache: &pathContainsCache) {
                return cheapIndexedPathExplanation(
                    snapshot: snapshot,
                    rowID: rowID,
                    token: token,
                    mode: mode
                )
            }
            return nil
        case .fileExtension(let pattern, let mode):
            return FuzzyMatcher.extensionExplanation(
                snapshot.store.fileExtension(at: rowID),
                pattern: pattern,
                mode: mode
            )
        case .kind(let token):
            guard !token.isEmpty else { return nil }
            let values: [String]
            if snapshot.store.isDirectory(at: rowID), snapshot.store.fileExtension(at: rowID) == "app" {
                values = ["app", "application", "folder", "directory", "dir"]
            } else {
                values = snapshot.store.isDirectory(at: rowID) ? ["folder", "directory", "dir"] : ["file"]
            }
            guard values.contains(where: { $0.hasPrefix(token) }) else { return nil }
            return MatchExplanation(
                matchClass: .metadata,
                score: 4_400,
                field: .kind,
                reason: "Kind matched \"\(token)\""
            )
        }
    }

    private static func cheapWildcardLiteralToken(_ token: String) -> String {
        token.filter { $0 != "*" && $0 != "?" && $0 != "[" && $0 != "]" && $0 != "!" && $0 != "^" }
    }

    private static func materialize(
        _ matches: [SearchMatch],
        from snapshot: SearchSnapshot,
        shouldCancel: @Sendable () -> Bool
    ) -> [SearchResult] {
        // Search cancellation is monotonic. The outer finish step rechecks it
        // before accepting the empty sentinel returned by a cancelled pass.
        guard !shouldCancel() else { return [] }

        var results: [SearchResult] = []
        results.reserveCapacity(matches.count)
        for (offset, match) in matches.enumerated() {
            if offset.isMultiple(of: 32), shouldCancel() {
                return []
            }
            results.append(SearchResult(
                record: snapshot.record(at: match.rowID),
                score: match.score,
                match: match.match,
                rootPath: snapshot.rootPath(at: match.rowID)
            ))
        }
        return shouldCancel() ? [] : results
    }

    private static func cancellableSorted<Element>(
        _ values: [Element],
        by areInIncreasingOrder: (Element, Element) -> Bool,
        shouldCancel: @Sendable () -> Bool
    ) -> [Element]? {
        guard !shouldCancel() else { return nil }
        guard values.count > 1 else { return values }

        var source = values
        var destination = values
        var width = 1
        var operationCount = 0

        func cancellationRequested() -> Bool {
            defer { operationCount += 1 }
            return operationCount.isMultiple(of: 256) && shouldCancel()
        }

        while width < source.count {
            var runStart = 0
            while runStart < source.count {
                let middle = min(runStart + width, source.count)
                let runEnd = min(middle + width, source.count)
                var left = runStart
                var right = middle
                var output = runStart

                while left < middle, right < runEnd {
                    if cancellationRequested() { return nil }
                    if areInIncreasingOrder(source[right], source[left]) {
                        destination[output] = source[right]
                        right += 1
                    } else {
                        destination[output] = source[left]
                        left += 1
                    }
                    output += 1
                }

                while left < middle {
                    if cancellationRequested() { return nil }
                    destination[output] = source[left]
                    left += 1
                    output += 1
                }

                while right < runEnd {
                    if cancellationRequested() { return nil }
                    destination[output] = source[right]
                    right += 1
                    output += 1
                }

                runStart = runEnd
            }

            swap(&source, &destination)
            width *= 2
        }

        return shouldCancel() ? nil : source
    }

    private static func fastModifiedInteractivePreviewSearch(
        snapshot: SearchSnapshot,
        request: SearchRequest,
        parsedQuery: FuzzyMatcher.ParsedQuery,
        maxResults: Int,
        started: Date,
        snapshotRevision: UInt64,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        guard
            request.mode == .interactivePreview,
            request.sort.column == .modified,
            snapshot.hasModifiedSortOrder,
            maxResults > 0,
            parsedQuery.negative.isEmpty,
            parsedQuery.positive.count == 1,
            let clause = parsedQuery.positive.first,
            clause.alternatives.count == 1,
            let part = clause.alternatives.first,
            case .text(let field, let pattern, let mode) = part,
            mode == .fuzzy || mode == .exact,
            !pattern.token.isEmpty,
            !tokenContainsPathSeparator(pattern.token)
        else {
            return nil
        }

        let orderedRows = request.includeHidden
            ? (request.sort.ascending ? snapshot.modifiedAscending : snapshot.modifiedDescending)
            : (request.sort.ascending ? snapshot.visibleModifiedAscending : snapshot.visibleModifiedDescending)
        guard !orderedRows.isEmpty else {
            return nil
        }

        var matches: [SearchMatch] = []
        matches.reserveCapacity(maxResults)
        var scannedRows = 0
        var directNameRows: [UInt8]?
        var directNameCandidateCount = 0
        var usedNameGrams = false
        if field != .path {
            guard let nameCandidates = snapshot.candidateNameIndices(
                containing: Array(pattern.token.utf8),
                shouldCancel: shouldCancel
            ) else {
                return modifiedPreviewResponseByScanningModifiedOrder(
                    snapshot: snapshot,
                    request: request,
                    orderedRows: orderedRows,
                    field: field,
                    token: pattern.token,
                    mode: mode,
                    maxResults: maxResults,
                    started: started,
                    snapshotRevision: snapshotRevision,
                    shouldCancel: shouldCancel
                )
            }
            usedNameGrams = true
            directNameCandidateCount = nameCandidates.count
            let pathAccelerationUnavailable = snapshot.gramIndex == nil && snapshot.pathGramShards.isEmpty
            if field == .name || nameCandidates.count <= maxResults || (field == .any && pathAccelerationUnavailable) {
                return modifiedPreviewResponseFromNameCandidates(
                    snapshot: snapshot,
                    request: request,
                    orderedRows: orderedRows,
                    nameCandidates: nameCandidates,
                    token: pattern.token,
                    mode: mode,
                    maxResults: maxResults,
                    started: started,
                    snapshotRevision: snapshotRevision,
                    shouldCancel: shouldCancel
                )
            } else {
                var rows = Array(repeating: UInt8(0), count: snapshot.count)
                for candidate in nameCandidates {
                    let rowID = Int(candidate)
                    guard rowID >= 0, rowID < snapshot.count else { continue }
                    rows[rowID] = 1
                }
                directNameRows = rows
            }
        }

        var indexesUsed: Set<SearchIndexUse> = [.modifiedOrder]
        if usedNameGrams {
            indexesUsed.insert(.nameGrams)
        }
        if !request.includeHidden {
            indexesUsed.insert(.visibleBitset)
        }

        var pathContainsCache: [Int: Bool] = [:]
        let pathScanLimit = field == .path ? max(maxResults * 25, 20_000) : max(maxResults * 4, 8_000)
        var selectedRows = Set<Int>()
        selectedRows.reserveCapacity(maxResults)

        for (offset, rowID) in orderedRows.enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }
            if scannedRows >= pathScanLimit, field != .name {
                break
            }

            scannedRows += 1
            guard rowID >= 0, rowID < snapshot.count else { continue }
            guard snapshot.store.isResultRow(at: rowID) else { continue }
            guard request.includeHidden || snapshot.isVisible(at: rowID) else { continue }

            let explanation: MatchExplanation
            if
                let directNameRows,
                directNameRows[rowID] != 0,
                let nameExplanation = cheapIndexedNameExplanation(
                    snapshot: snapshot,
                    rowID: rowID,
                    token: pattern.token,
                    mode: mode
                )
            {
                explanation = nameExplanation
            } else if field != .name,
                      snapshot.store.normalizedPath(at: rowID, contains: pattern.token, cache: &pathContainsCache) {
                explanation = cheapIndexedPathExplanation(
                    snapshot: snapshot,
                    rowID: rowID,
                    token: pattern.token,
                    mode: mode
                )
            } else {
                continue
            }

            guard selectedRows.insert(rowID).inserted else { continue }
            matches.append(SearchMatch(rowID: rowID, score: explanation.score, match: explanation))
            if matches.count == maxResults {
                break
            }
        }

        guard !shouldCancel() else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        return SearchResponse(
            results: materialize(matches, from: snapshot, shouldCancel: shouldCancel),
            totalMatches: matches.count,
            elapsed: elapsed,
            snapshotRevision: snapshotRevision,
            usesIndexedCandidates: true,
            executionProfile: SearchExecutionProfile(
                executionPath: .optimizedSortedFastPath,
                indexesUsed: indexesUsed,
                candidateCount: max(matches.count, directNameCandidateCount),
                scannedRowCount: scannedRows,
                elapsed: elapsed
            )
        )
    }

    private static func modifiedPreviewResponseByScanningModifiedOrder(
        snapshot: SearchSnapshot,
        request: SearchRequest,
        orderedRows: [Int],
        field: FuzzyMatcher.QueryField,
        token: String,
        mode: FuzzyMatcher.MatchMode,
        maxResults: Int,
        started: Date,
        snapshotRevision: UInt64,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        guard maxResults > 0, field != .path else {
            return nil
        }

        let scanLimit = min(orderedRows.count, max(maxResults * 250, 250_000))
        var matches: [SearchMatch] = []
        matches.reserveCapacity(maxResults)
        var scannedRows = 0

        for (offset, rowID) in orderedRows.prefix(scanLimit).enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }
            scannedRows += 1
            guard rowID >= 0, rowID < snapshot.count else { continue }
            guard snapshot.store.isResultRow(at: rowID) else { continue }
            guard request.includeHidden || snapshot.isVisible(at: rowID) else { continue }
            guard let explanation = cheapLiteralNameExplanation(
                snapshot: snapshot,
                rowID: rowID,
                token: token,
                mode: mode
            ) else {
                continue
            }

            matches.append(SearchMatch(rowID: rowID, score: explanation.score, match: explanation))
            if matches.count == maxResults {
                break
            }
        }

        guard !shouldCancel() else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        var indexesUsed: Set<SearchIndexUse> = [.modifiedOrder]
        if !request.includeHidden {
            indexesUsed.insert(.visibleBitset)
        }
        return SearchResponse(
            results: materialize(matches, from: snapshot, shouldCancel: shouldCancel),
            totalMatches: matches.count,
            elapsed: elapsed,
            snapshotRevision: snapshotRevision,
            usesIndexedCandidates: true,
            executionProfile: SearchExecutionProfile(
                executionPath: .optimizedSortedFastPath,
                indexesUsed: indexesUsed,
                candidateCount: matches.count,
                scannedRowCount: scannedRows,
                elapsed: elapsed
            )
        )
    }

    private static func fastModifiedNameOnlyInteractivePreviewScan(
        snapshot: SearchSnapshot,
        request: SearchRequest,
        parsedQuery: FuzzyMatcher.ParsedQuery,
        maxResults: Int,
        started: Date,
        snapshotRevision: UInt64,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        guard
            request.mode == .interactivePreview,
            request.sort.column == .modified,
            !snapshot.hasModifiedSortOrder,
            maxResults > 0,
            parsedQuery.negative.isEmpty,
            parsedQuery.positive.count == 1,
            let clause = parsedQuery.positive.first,
            clause.alternatives.count == 1,
            let part = clause.alternatives.first,
            case .text(let field, let pattern, let mode) = part,
            field != .path,
            mode == .fuzzy || mode == .exact,
            !pattern.token.isEmpty,
            !tokenContainsPathSeparator(pattern.token)
        else {
            return nil
        }

        var matches: [SearchMatch] = []
        matches.reserveCapacity(maxResults)
        let trimThreshold = maxResults * 5
        let tokenBytes = Array(pattern.token.utf8)
        var total = 0
        var scannedRows = 0

        func sortAndLimitMatches() {
            matches.sort {
                compare($0, $1, snapshot: snapshot, sort: request.sort, queryIsEmpty: false)
            }
            if matches.count > maxResults {
                matches.removeSubrange(maxResults..<matches.count)
            }
        }

        for rowID in 0..<snapshot.count {
            if rowID.isMultiple(of: 512), shouldCancel() {
                return nil
            }

            scannedRows += 1
            guard snapshot.store.isResultRow(at: rowID) else { continue }
            guard request.includeHidden || snapshot.isVisible(at: rowID) else { continue }
            guard snapshot.store.normalizedName(at: rowID, contains: tokenBytes) else { continue }
            guard let explanation = cheapIndexedNameExplanation(
                snapshot: snapshot,
                rowID: rowID,
                token: pattern.token,
                mode: mode
            ) else {
                continue
            }

            total += 1
            matches.append(SearchMatch(rowID: rowID, score: explanation.score, match: explanation))
            if matches.count > trimThreshold {
                sortAndLimitMatches()
            }
        }

        guard total > 0 else {
            return nil
        }

        guard !shouldCancel() else { return nil }
        sortAndLimitMatches()

        let elapsed = Date().timeIntervalSince(started)
        var indexesUsed: Set<SearchIndexUse> = []
        if !request.includeHidden {
            indexesUsed.insert(.visibleBitset)
        }
        return SearchResponse(
            results: materialize(matches, from: snapshot, shouldCancel: shouldCancel),
            totalMatches: total,
            elapsed: elapsed,
            snapshotRevision: snapshotRevision,
            usesIndexedCandidates: false,
            executionProfile: SearchExecutionProfile(
                executionPath: .optimizedSortedFastPath,
                indexesUsed: indexesUsed,
                candidateCount: snapshot.count,
                scannedRowCount: scannedRows,
                elapsed: elapsed
            )
        )
    }

    private static func modifiedPreviewResponseFromNameCandidates(
        snapshot: SearchSnapshot,
        request: SearchRequest,
        orderedRows: [Int],
        nameCandidates: [Int32],
        token: String,
        mode: FuzzyMatcher.MatchMode,
        maxResults: Int,
        started: Date,
        snapshotRevision: UInt64,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        var nameRows = Array(repeating: UInt8(0), count: snapshot.count)
        var visibleNameCandidateRows: [Int] = []
        visibleNameCandidateRows.reserveCapacity(min(nameCandidates.count, maxResults))
        for (offset, candidate) in nameCandidates.enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }
            let rowID = Int(candidate)
            guard rowID >= 0, rowID < snapshot.count else { continue }
            guard snapshot.store.isResultRow(at: rowID) else { continue }
            guard request.includeHidden || snapshot.isVisible(at: rowID) else { continue }
            visibleNameCandidateRows.append(rowID)
            nameRows[rowID] = 1
        }

        guard !visibleNameCandidateRows.isEmpty else {
            guard !shouldCancel() else { return nil }
            let elapsed = Date().timeIntervalSince(started)
            var indexesUsed: Set<SearchIndexUse> = [.nameGrams, .modifiedOrder]
            if !request.includeHidden {
                indexesUsed.insert(.visibleBitset)
            }
            return SearchResponse(
                results: [],
                totalMatches: 0,
                elapsed: elapsed,
                snapshotRevision: snapshotRevision,
                usesIndexedCandidates: true,
                executionProfile: SearchExecutionProfile(
                    executionPath: .optimizedSortedFastPath,
                    indexesUsed: indexesUsed,
                    candidateCount: nameCandidates.count,
                    scannedRowCount: 0,
                    elapsed: elapsed
                )
            )
        }

        if visibleNameCandidateRows.count <= maxResults {
            var matches: [SearchMatch] = []
            matches.reserveCapacity(visibleNameCandidateRows.count)
            for rowID in visibleNameCandidateRows {
                guard let explanation = cheapIndexedNameExplanation(
                    snapshot: snapshot,
                    rowID: rowID,
                    token: token,
                    mode: mode
                ) else {
                    continue
                }
                matches.append(SearchMatch(rowID: rowID, score: explanation.score, match: explanation))
            }
            matches.sort {
                compare($0, $1, snapshot: snapshot, sort: request.sort, queryIsEmpty: false)
            }

            guard !shouldCancel() else { return nil }
            let elapsed = Date().timeIntervalSince(started)
            var indexesUsed: Set<SearchIndexUse> = [.nameGrams, .modifiedOrder]
            if !request.includeHidden {
                indexesUsed.insert(.visibleBitset)
            }
            return SearchResponse(
                results: materialize(matches, from: snapshot, shouldCancel: shouldCancel),
                totalMatches: matches.count,
                elapsed: elapsed,
                snapshotRevision: snapshotRevision,
                usesIndexedCandidates: true,
                executionProfile: SearchExecutionProfile(
                    executionPath: .optimizedSortedFastPath,
                    indexesUsed: indexesUsed,
                    candidateCount: nameCandidates.count,
                    scannedRowCount: visibleNameCandidateRows.count,
                    elapsed: elapsed
                )
            )
        }

        var matches: [SearchMatch] = []
        matches.reserveCapacity(maxResults)
        var scannedRows = 0
        for (offset, rowID) in orderedRows.enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }
            scannedRows += 1
            guard rowID >= 0, rowID < snapshot.count else { continue }
            guard nameRows[rowID] != 0 else { continue }
            guard let explanation = cheapIndexedNameExplanation(
                snapshot: snapshot,
                rowID: rowID,
                token: token,
                mode: mode
            ) else {
                continue
            }
            matches.append(SearchMatch(rowID: rowID, score: explanation.score, match: explanation))
            if matches.count == maxResults {
                break
            }
        }

        guard !shouldCancel() else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        var indexesUsed: Set<SearchIndexUse> = [.nameGrams, .modifiedOrder]
        if !request.includeHidden {
            indexesUsed.insert(.visibleBitset)
        }
        return SearchResponse(
            results: materialize(matches, from: snapshot, shouldCancel: shouldCancel),
            totalMatches: matches.count,
            elapsed: elapsed,
            snapshotRevision: snapshotRevision,
            usesIndexedCandidates: true,
            executionProfile: SearchExecutionProfile(
                executionPath: .optimizedSortedFastPath,
                indexesUsed: indexesUsed,
                candidateCount: nameCandidates.count,
                scannedRowCount: scannedRows,
                elapsed: elapsed
            )
        )
    }

    private static func fastRelevanceInteractivePreviewSearch(
        snapshot: SearchSnapshot,
        request: SearchRequest,
        parsedQuery: FuzzyMatcher.ParsedQuery,
        maxResults: Int,
        started: Date,
        snapshotRevision: UInt64,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        guard
            request.mode == .interactivePreview,
            request.sort.column == .relevance,
            maxResults > 0,
            parsedQuery.negative.isEmpty,
            parsedQuery.positive.count == 1,
            let clause = parsedQuery.positive.first,
            clause.alternatives.count == 1,
            let part = clause.alternatives.first,
            case .text(let field, let pattern, let mode) = part,
            field != .path,
            mode == .fuzzy || mode == .exact,
            !pattern.token.isEmpty,
            !tokenContainsPathSeparator(pattern.token)
        else {
            return nil
        }

        let weakPathCeiling = indexedQualityCode(MatchQuality(matchClass: .weakPath, scoreBin: 4))
        var heap: [RelevancePreviewCandidate] = []
        heap.reserveCapacity(maxResults)
        var totalNameMatches = 0
        var scannedRows = 0
        var scannedPrefixOrder = false

        func precedes(_ lhs: RelevancePreviewCandidate, _ rhs: RelevancePreviewCandidate) -> Bool {
            if lhs.qualityCode != rhs.qualityCode {
                return lhs.qualityCode > rhs.qualityCode
            }
            if lhs.normalizedName != rhs.normalizedName {
                return lhs.normalizedName < rhs.normalizedName
            }
            return lhs.rowID < rhs.rowID
        }

        func isWorse(_ lhs: RelevancePreviewCandidate, than rhs: RelevancePreviewCandidate) -> Bool {
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

        func appendToHeap(_ candidate: RelevancePreviewCandidate) {
            if heap.count < maxResults {
                heap.append(candidate)
                siftUp(heap.count - 1)
            } else if let worst = heap.first, precedes(candidate, worst) {
                heap[0] = candidate
                siftDown(0)
            }
        }

        func makeCandidate(rowID: Int, explanation: MatchExplanation) -> RelevancePreviewCandidate {
            RelevancePreviewCandidate(
                rowID: rowID,
                qualityCode: indexedQualityCode(explanation.quality),
                normalizedName: snapshot.store.normalizedName(at: rowID),
                match: explanation
            )
        }

        func response(candidateCount: Int, indexesUsed: Set<SearchIndexUse>) -> SearchResponse {
            let matches = heap.sorted(by: precedes).map {
                SearchMatch(rowID: $0.rowID, score: $0.match.score, match: $0.match)
            }
            let elapsed = Date().timeIntervalSince(started)
            let usesIndexedCandidates = !indexesUsed.isEmpty
            var indexesUsed = indexesUsed
            if !request.includeHidden {
                indexesUsed.insert(.visibleBitset)
            }
            return SearchResponse(
                results: materialize(matches, from: snapshot, shouldCancel: shouldCancel),
                totalMatches: max(totalNameMatches, matches.count),
                elapsed: elapsed,
                snapshotRevision: snapshotRevision,
                usesIndexedCandidates: usesIndexedCandidates,
                executionProfile: SearchExecutionProfile(
                    executionPath: .optimizedSortedFastPath,
                    indexesUsed: indexesUsed,
                    candidateCount: candidateCount,
                    scannedRowCount: scannedRows,
                    elapsed: elapsed
                )
            )
        }

        if snapshot.hasSortedOrder, !snapshot.nameAscending.isEmpty {
            scannedPrefixOrder = true
            let lowerBound = lowerBoundName(in: snapshot.nameAscending, snapshot: snapshot, key: pattern.token)
            var cursor = lowerBound
            while cursor < snapshot.nameAscending.count {
                if cursor.isMultiple(of: 512), shouldCancel() {
                    return nil
                }

                let rowID = snapshot.nameAscending[cursor]
                let normalizedName = snapshot.store.normalizedName(at: rowID)
                guard normalizedName.hasPrefix(pattern.token) else { break }

                let groupName = normalizedName
                var group: [RelevancePreviewCandidate] = []
                while cursor < snapshot.nameAscending.count {
                    let groupRowID = snapshot.nameAscending[cursor]
                    guard snapshot.store.normalizedName(at: groupRowID) == groupName else { break }
                    cursor += 1
                    scannedRows += 1
                    guard groupRowID >= 0, groupRowID < snapshot.count else { continue }
                    guard snapshot.store.isResultRow(at: groupRowID) else { continue }
                    guard request.includeHidden || snapshot.isVisible(at: groupRowID) else { continue }
                    guard let explanation = cheapLiteralNameExplanation(
                        snapshot: snapshot,
                        rowID: groupRowID,
                        token: pattern.token,
                        mode: mode
                    ) else {
                        continue
                    }

                    let candidate = makeCandidate(rowID: groupRowID, explanation: explanation)
                    guard candidate.qualityCode > weakPathCeiling else { continue }
                    totalNameMatches += 1
                    group.append(candidate)
                }

                group.sort(by: precedes)
                for candidate in group {
                    appendToHeap(candidate)
                }

                if heap.count == maxResults {
                    guard !shouldCancel() else { return nil }
                    return response(candidateCount: scannedRows, indexesUsed: [.nameGrams])
                }
            }
        }

        let tokenBytes = Array(pattern.token.utf8)
        let nameCandidates = snapshot.candidateNameIndices(
            containing: tokenBytes,
            shouldCancel: shouldCancel
        )

        func visitCandidate(rowID: Int) {
            guard rowID >= 0, rowID < snapshot.count else { return }
            scannedRows += 1
            guard snapshot.store.isResultRow(at: rowID) else { return }
            guard request.includeHidden || snapshot.isVisible(at: rowID) else { return }
            guard snapshot.store.normalizedName(at: rowID, contains: tokenBytes) else { return }
            guard let explanation = cheapLiteralNameExplanation(
                snapshot: snapshot,
                rowID: rowID,
                token: pattern.token,
                mode: mode
            ) else {
                return
            }

            let qualityCode = indexedQualityCode(explanation.quality)
            guard qualityCode > weakPathCeiling else { return }
            if scannedPrefixOrder {
                guard !snapshot.store.normalizedName(at: rowID).hasPrefix(pattern.token) else { return }
            }

            totalNameMatches += 1
            appendToHeap(makeCandidate(rowID: rowID, explanation: explanation))
        }

        if let nameCandidates {
            for (offset, candidate) in nameCandidates.enumerated() {
                if offset.isMultiple(of: 512), shouldCancel() {
                    return nil
                }
                visitCandidate(rowID: Int(candidate))
            }
        } else {
            for rowID in 0..<snapshot.count {
                if rowID.isMultiple(of: 512), shouldCancel() {
                    return nil
                }
                visitCandidate(rowID: rowID)
            }
        }

        let shouldAppendWeakPathMatches = heap.isEmpty || heap.contains { snapshot.store.isDirectory(at: $0.rowID) }
        if heap.count < maxResults, field != .name, shouldAppendWeakPathMatches {
            let existingRows = Set(heap.map(\.rowID))
            if let appended = appendWeakPathPreviewCandidates(
                snapshot: snapshot,
                token: pattern.token,
                mode: mode,
                request: request,
                maxResults: maxResults,
                existingRows: existingRows,
                heapCount: { heap.count },
                appendCandidate: { appendToHeap($0) },
                makeCandidate: makeCandidate,
                shouldCancel: shouldCancel
            ) {
                scannedRows += appended.scannedRows
                if appended.candidateCount > 0 {
                    var previewIndexesUsed: Set<SearchIndexUse> = []
                    if nameCandidates != nil {
                        previewIndexesUsed.insert(.nameGrams)
                    }
                    previewIndexesUsed.insert(.componentGrams)
                    guard !shouldCancel() else { return nil }
                    return response(
                        candidateCount: (nameCandidates?.count ?? 0) + appended.candidateCount,
                        indexesUsed: previewIndexesUsed
                    )
                }
            }
        }

        guard !heap.isEmpty else {
            return nil
        }

        guard !shouldCancel() else { return nil }
        var indexesUsed: Set<SearchIndexUse> = []
        if nameCandidates != nil {
            indexesUsed.insert(.nameGrams)
        }
        return response(candidateCount: nameCandidates?.count ?? snapshot.count, indexesUsed: indexesUsed)
    }

    private struct WeakPathPreviewAppendResult {
        let candidateCount: Int
        let scannedRows: Int
    }

    private static func appendWeakPathPreviewCandidates(
        snapshot: SearchSnapshot,
        token: String,
        mode: FuzzyMatcher.MatchMode,
        request: SearchRequest,
        maxResults: Int,
        existingRows: Set<Int>,
        heapCount: () -> Int,
        appendCandidate: (RelevancePreviewCandidate) -> Void,
        makeCandidate: (Int, MatchExplanation) -> RelevancePreviewCandidate,
        shouldCancel: @Sendable () -> Bool
    ) -> WeakPathPreviewAppendResult? {
        guard let componentCandidates = snapshot.candidateComponentIndices(
            containing: Array(token.utf8),
            shouldCancel: shouldCancel
        ) else {
            return nil
        }

        var selectedRows = existingRows
        var scannedRows = 0

        func appendSubtree(startingAt directRow: Int) -> Bool? {
            snapshot.visitSubtreeRows(startingAt: directRow, shouldCancel: shouldCancel) { rowID in
                scannedRows += 1
                guard snapshot.store.isResultRow(at: rowID) else { return true }
                guard request.includeHidden || snapshot.isVisible(at: rowID) else { return true }
                guard selectedRows.insert(rowID).inserted else { return true }

                let explanation = cheapIndexedPathExplanation(
                    snapshot: snapshot,
                    rowID: rowID,
                    token: token,
                    mode: mode
                )
                appendCandidate(makeCandidate(rowID, explanation))
                if heapCount() == maxResults {
                    return false
                }
                return true
            }
        }

        var foundDirectRow = false
        for (offset, candidate) in componentCandidates.enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }

            let rowID = Int(candidate)
            guard rowID >= 0, rowID < snapshot.count else { continue }
            guard snapshot.store.normalizedName(at: rowID, contains: token) else { continue }
            foundDirectRow = true
            guard let shouldContinue = appendSubtree(startingAt: rowID) else {
                return nil
            }
            if !shouldContinue {
                return WeakPathPreviewAppendResult(
                    candidateCount: componentCandidates.count,
                    scannedRows: scannedRows
                )
            }
        }

        guard foundDirectRow else {
            return WeakPathPreviewAppendResult(candidateCount: componentCandidates.count, scannedRows: scannedRows)
        }

        return WeakPathPreviewAppendResult(candidateCount: componentCandidates.count, scannedRows: scannedRows)
    }

    private static func fastNameCandidateInteractivePreviewSearch(
        snapshot: SearchSnapshot,
        request: SearchRequest,
        parsedQuery: FuzzyMatcher.ParsedQuery,
        maxResults: Int,
        started: Date,
        snapshotRevision: UInt64,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        guard
            request.mode == .interactivePreview,
            request.sort.column == .name,
            !snapshot.hasSortedOrder,
            maxResults > 0,
            parsedQuery.negative.isEmpty,
            parsedQuery.positive.count == 1,
            let clause = parsedQuery.positive.first,
            clause.alternatives.count == 1,
            let part = clause.alternatives.first,
            case .text(let field, let pattern, let mode) = part,
            field != .path,
            mode == .fuzzy || mode == .exact,
            !pattern.token.isEmpty,
            !tokenContainsPathSeparator(pattern.token)
        else {
            return nil
        }

        let tokenBytes = Array(pattern.token.utf8)
        let nameCandidates = snapshot.candidateNameIndices(
            containing: tokenBytes,
            shouldCancel: shouldCancel
        )
        let ascending = request.sort.ascending
        var heap: [NamePreviewCandidate] = []
        heap.reserveCapacity(maxResults)
        var totalNameMatches = 0
        var scannedRows = 0

        func precedes(_ lhs: NamePreviewCandidate, _ rhs: NamePreviewCandidate) -> Bool {
            if lhs.qualityCode != rhs.qualityCode {
                return lhs.qualityCode > rhs.qualityCode
            }
            if lhs.normalizedName != rhs.normalizedName {
                return ascending ? lhs.normalizedName < rhs.normalizedName : lhs.normalizedName > rhs.normalizedName
            }
            return lhs.rowID < rhs.rowID
        }

        func isWorse(_ lhs: NamePreviewCandidate, than rhs: NamePreviewCandidate) -> Bool {
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

        func appendToHeap(_ candidate: NamePreviewCandidate) {
            if heap.count < maxResults {
                heap.append(candidate)
                siftUp(heap.count - 1)
            } else if let worst = heap.first, precedes(candidate, worst) {
                heap[0] = candidate
                siftDown(0)
            }
        }

        func visitCandidate(rowID: Int) {
            scannedRows += 1
            guard rowID >= 0, rowID < snapshot.count else { return }
            guard snapshot.store.isResultRow(at: rowID) else { return }
            guard request.includeHidden || snapshot.isVisible(at: rowID) else { return }
            guard snapshot.store.normalizedName(at: rowID, contains: tokenBytes) else { return }
            guard let explanation = cheapLiteralNameExplanation(
                snapshot: snapshot,
                rowID: rowID,
                token: pattern.token,
                mode: mode
            ) else {
                return
            }

            totalNameMatches += 1
            appendToHeap(NamePreviewCandidate(
                rowID: rowID,
                qualityCode: indexedQualityCode(explanation.quality),
                normalizedName: snapshot.store.normalizedName(at: rowID),
                match: explanation
            ))
        }

        if let nameCandidates {
            for (offset, candidate) in nameCandidates.enumerated() {
                if offset.isMultiple(of: 512), shouldCancel() {
                    return nil
                }
                visitCandidate(rowID: Int(candidate))
            }
        } else {
            for rowID in 0..<snapshot.count {
                if rowID.isMultiple(of: 512), shouldCancel() {
                    return nil
                }
                visitCandidate(rowID: rowID)
            }
        }

        guard !heap.isEmpty else {
            return nil
        }

        guard !shouldCancel() else { return nil }
        let matches = heap.sorted(by: precedes).map {
            SearchMatch(rowID: $0.rowID, score: $0.match.score, match: $0.match)
        }
        let elapsed = Date().timeIntervalSince(started)
        var indexesUsed: Set<SearchIndexUse> = []
        if nameCandidates != nil {
            indexesUsed.insert(.nameGrams)
        }
        if !request.includeHidden {
            indexesUsed.insert(.visibleBitset)
        }
        return SearchResponse(
            results: materialize(matches, from: snapshot, shouldCancel: shouldCancel),
            totalMatches: totalNameMatches,
            elapsed: elapsed,
            snapshotRevision: snapshotRevision,
            usesIndexedCandidates: nameCandidates != nil,
            executionProfile: SearchExecutionProfile(
                executionPath: .optimizedSortedFastPath,
                indexesUsed: indexesUsed,
                candidateCount: nameCandidates?.count ?? snapshot.count,
                scannedRowCount: scannedRows,
                elapsed: elapsed
            )
        )
    }

    private static func fastNameInteractivePreviewSearch(
        snapshot: SearchSnapshot,
        request: SearchRequest,
        parsedQuery: FuzzyMatcher.ParsedQuery,
        maxResults: Int,
        started: Date,
        snapshotRevision: UInt64,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        guard
            request.mode == .interactivePreview,
            request.sort.column == .name,
            snapshot.hasSortedOrder,
            maxResults > 0,
            parsedQuery.negative.isEmpty,
            parsedQuery.positive.count == 1,
            let clause = parsedQuery.positive.first,
            clause.alternatives.count == 1,
            let part = clause.alternatives.first,
            case .text(let field, let pattern, let mode) = part,
            field != .path,
            mode == .fuzzy || mode == .exact,
            !pattern.token.isEmpty,
            !tokenContainsPathSeparator(pattern.token),
            !snapshot.nameAscending.isEmpty
        else {
            return nil
        }

        let token = pattern.token
        let tokenBytes = Array(token.utf8)
        let nameCandidates = snapshot.candidateNameIndices(
            containing: tokenBytes,
            shouldCancel: shouldCancel
        )
        let directCandidateLimit = maxResults > Int.max / 4 ? Int.max : maxResults * 4
        if let nameCandidates, nameCandidates.count <= directCandidateLimit {
            var matches: [SearchMatch] = []
            matches.reserveCapacity(min(nameCandidates.count, maxResults))
            var total = 0

            for (offset, candidate) in nameCandidates.enumerated() {
                if offset.isMultiple(of: 512), shouldCancel() {
                    return nil
                }
                let rowID = Int(candidate)
                guard rowID >= 0, rowID < snapshot.count else { continue }
                guard snapshot.store.isResultRow(at: rowID) else { continue }
                guard request.includeHidden || snapshot.isVisible(at: rowID) else { continue }
                guard let explanation = cheapLiteralNameExplanation(
                    snapshot: snapshot,
                    rowID: rowID,
                    token: token,
                    mode: mode
                ) else {
                    continue
                }
                total += 1
                matches.append(SearchMatch(rowID: rowID, score: explanation.score, match: explanation))
            }

            guard !matches.isEmpty else { return nil }
            guard let sortedMatches = cancellableSorted(
                matches,
                by: { compare($0, $1, snapshot: snapshot, sort: request.sort, queryIsEmpty: false) },
                shouldCancel: shouldCancel
            ) else { return nil }
            matches = sortedMatches
            if matches.count > maxResults {
                matches.removeSubrange(maxResults..<matches.count)
            }

            let elapsed = Date().timeIntervalSince(started)
            var indexesUsed: Set<SearchIndexUse> = [.nameGrams]
            if !request.includeHidden {
                indexesUsed.insert(.visibleBitset)
            }
            return SearchResponse(
                results: materialize(matches, from: snapshot, shouldCancel: shouldCancel),
                totalMatches: total,
                elapsed: elapsed,
                snapshotRevision: snapshotRevision,
                usesIndexedCandidates: true,
                executionProfile: SearchExecutionProfile(
                    executionPath: .nameComponentIndex,
                    indexesUsed: indexesUsed,
                    candidateCount: nameCandidates.count,
                    scannedRowCount: nameCandidates.count,
                    elapsed: elapsed
                )
            )
        }
        var candidateRows: [UInt8]?
        if let nameCandidates {
            var rows = Array(repeating: UInt8(0), count: snapshot.count)
            for (offset, candidate) in nameCandidates.enumerated() {
                if offset.isMultiple(of: 512), shouldCancel() {
                    return nil
                }
                let rowID = Int(candidate)
                guard rowID >= 0, rowID < snapshot.count else { continue }
                rows[rowID] = 1
            }
            candidateRows = rows
        }

        var matches: [SearchMatch] = []
        matches.reserveCapacity(maxResults)
        var selectedRows = Set<Int>()
        selectedRows.reserveCapacity(maxResults)
        var scannedRows = 0

        func appendNameMatch(rowID: Int, requiresCandidateMembership: Bool = true) {
            guard matches.count < maxResults else { return }
            guard rowID >= 0, rowID < snapshot.count else { return }
            guard !selectedRows.contains(rowID) else { return }
            guard snapshot.store.isResultRow(at: rowID) else { return }
            guard request.includeHidden || snapshot.isVisible(at: rowID) else { return }
            if requiresCandidateMembership, let candidateRows, candidateRows[rowID] == 0 {
                return
            }
            guard let explanation = cheapLiteralNameExplanation(
                snapshot: snapshot,
                rowID: rowID,
                token: token,
                mode: mode
            ) else {
                return
            }
            guard selectedRows.insert(rowID).inserted else { return }
            matches.append(SearchMatch(rowID: rowID, score: explanation.score, match: explanation))
        }

        let lowerBound = lowerBoundName(in: snapshot.nameAscending, snapshot: snapshot, key: token)
        if lowerBound < snapshot.nameAscending.count {
            let upperBound = lowerBoundName(
                in: snapshot.nameAscending,
                snapshot: snapshot,
                key: token + "\u{10FFFF}"
            )
            var exactEnd = lowerBound
            while exactEnd < upperBound,
                  snapshot.store.normalizedName(at: snapshot.nameAscending[exactEnd]) == token {
                if exactEnd.isMultiple(of: 512), shouldCancel() {
                    return nil
                }
                let rowID = snapshot.nameAscending[exactEnd]
                scannedRows += 1
                appendNameMatch(rowID: rowID, requiresCandidateMembership: false)
                if matches.count == maxResults {
                    break
                }
                exactEnd += 1
            }

            if matches.count < maxResults {
                let prefixRange = exactEnd..<upperBound
                let prefixRows: AnySequence<Int>
                if request.sort.ascending {
                    prefixRows = AnySequence(prefixRange.lazy.map { snapshot.nameAscending[$0] })
                } else {
                    prefixRows = AnySequence(prefixRange.reversed().lazy.map { snapshot.nameAscending[$0] })
                }

                for rowID in prefixRows {
                    if scannedRows.isMultiple(of: 512), shouldCancel() {
                        return nil
                    }
                    scannedRows += 1
                    appendNameMatch(rowID: rowID, requiresCandidateMembership: false)
                    if matches.count == maxResults {
                        break
                    }
                }
            }
        }

        if matches.count < maxResults {
            let order = request.sort.ascending ? snapshot.nameAscending : snapshot.nameDescending
            let scanLimit = min(order.count, max(maxResults * 250, 250_000))
            for (offset, rowID) in order.prefix(scanLimit).enumerated() {
                if offset.isMultiple(of: 512), shouldCancel() {
                    return nil
                }
                scannedRows += 1
                appendNameMatch(rowID: rowID)
                if matches.count == maxResults {
                    break
                }
            }
        }

        guard !matches.isEmpty else {
            return nil
        }

        let elapsed = Date().timeIntervalSince(started)
        var indexesUsed: Set<SearchIndexUse> = [.sortOrder]
        if nameCandidates != nil {
            indexesUsed.insert(.nameGrams)
        }
        if !request.includeHidden {
            indexesUsed.insert(.visibleBitset)
        }
        return SearchResponse(
            results: materialize(matches, from: snapshot, shouldCancel: shouldCancel),
            totalMatches: matches.count,
            elapsed: elapsed,
            snapshotRevision: snapshotRevision,
            usesIndexedCandidates: true,
            executionProfile: SearchExecutionProfile(
                executionPath: .optimizedSortedFastPath,
                indexesUsed: indexesUsed,
                candidateCount: nameCandidates?.count ?? matches.count,
                scannedRowCount: scannedRows,
                elapsed: elapsed
            )
        )
    }

    private static func lowerBoundName(in order: [Int], snapshot: SearchSnapshot, key: String) -> Int {
        var low = 0
        var high = order.count
        while low < high {
            let middle = low + (high - low) / 2
            if snapshot.store.normalizedName(at: order[middle]) < key {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private static func fastComponentNameSortedSearch(
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
        let isPreview = request.mode == .interactivePreview

        var intervals: [RowInterval] = []
        var directNameRows = Array(repeating: UInt8(0), count: snapshot.count)
        var directNameRowIDs: [Int] = []
        if field != .name {
            let usesShortFuzzyPathExpansion = shortFuzzy && (!isPreview || field == .path)
            guard let pathIntervals = snapshot.componentPathIntervalSet(
                containing: pattern.token,
                tokenBytes: tokenBytes,
                shortFuzzy: usesShortFuzzyPathExpansion,
                shouldCancel: shouldCancel
            ) else {
                return nil
            }
            intervals.append(contentsOf: pathIntervals.intervals)
        }

        if field != .path {
            let nameCandidates: [Int32]?
            if mode == .fuzzy && shortFuzzy && (!isPreview || field == .name) {
                nameCandidates = shortFuzzyNameCandidateIndices(
                    snapshot: snapshot,
                    tokenBytes: tokenBytes,
                    shouldCancel: shouldCancel
                )
            } else if mode == .fuzzy && (!isPreview || field == .name) {
                nameCandidates = fuzzyNameCandidateIndices(
                    snapshot: snapshot,
                    tokenBytes: tokenBytes,
                    shouldCancel: shouldCancel
                )
            } else {
                nameCandidates = snapshot.candidateNameIndices(
                    containing: tokenBytes,
                    shouldCancel: shouldCancel
                )
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
                if mode == .fuzzy && !shortFuzzy && (!isPreview || field == .name) {
                    guard FuzzyMatcher.score(record: snapshot.view(at: rowID), parsedQuery: parsedQuery) != nil else {
                        continue
                    }
                }
                if directNameRows[rowID] == 0 {
                    directNameRows[rowID] = 1
                    directNameRowIDs.append(rowID)
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

        if let selected = nameSortedComponentPathIntervalMatches(
            snapshot: snapshot,
            rowSet: rowSet,
            directNameRows: directNameRows,
            directNameRowIDs: directNameRowIDs,
            token: pattern.token,
            mode: mode,
            field: field,
            request: request,
            maxResults: maxResults,
            shouldCancel: shouldCancel
        ) {
            let elapsed = Date().timeIntervalSince(started)
            let candidateCount = rowSet.intervals.reduce(0) { $0 + max($1.end - $1.start, 0) }
            return SearchResponse(
                results: materialize(selected.matches, from: snapshot, shouldCancel: shouldCancel),
                totalMatches: selected.total,
                elapsed: elapsed,
                snapshotRevision: snapshotRevision,
                usesIndexedCandidates: true,
                executionProfile: SearchExecutionProfile(
                    executionPath: .optimizedSortedFastPath,
                    indexesUsed: [.nameGrams, .componentGrams],
                    candidateCount: candidateCount,
                    scannedRowCount: selected.scannedRowCount,
                    elapsed: elapsed
                )
            )
        }

        var matches: [SearchMatch] = []
        matches.reserveCapacity(maxResults)
        let trimThreshold = maxResults * 5
        var total = 0
        var includedQuality = snapshot.nameAscending.isEmpty
            ? nil
            : Array(repeating: UInt8(0), count: snapshot.count)

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
                let explanation: MatchExplanation
                if directNameRows[rowID] != 0, field != .path, let nameExplanation = cheapIndexedNameExplanation(
                        snapshot: snapshot,
                        rowID: rowID,
                        token: pattern.token,
                        mode: mode
                    ) {
                    explanation = nameExplanation
                } else if field != .name {
                    explanation = cheapIndexedPathExplanation(
                        snapshot: snapshot,
                        rowID: rowID,
                        token: pattern.token,
                        mode: mode
                    )
                } else {
                    continue
                }

                total += 1
                if includedQuality != nil {
                    let qualityCode = indexedQualityCode(explanation.quality)
                    includedQuality?[rowID] = qualityCode &+ 1
                } else {
                    matches.append(SearchMatch(rowID: rowID, score: explanation.score, match: explanation))
                    if matches.count > trimThreshold {
                        sortAndLimitMatches()
                    }
                }
            }
        }

        guard !shouldCancel() else { return nil }
        if let includedQuality {
            let order = request.sort.ascending ? snapshot.nameAscending : snapshot.nameDescending
            var qualityBuckets = (0..<(MatchClass.allCases.count * 5)).map { _ in [Int]() }

            for (offset, rowID) in order.enumerated() {
                if offset & 511 == 0, shouldCancel() {
                    return nil
                }

                let marker = includedQuality[rowID]
                guard marker != 0 else { continue }
                qualityBuckets[Int(marker - 1)].append(rowID)
            }

            var reachedLimit = false

            for qualityCode in stride(from: qualityBuckets.count - 1, through: 0, by: -1) {
                for rowID in qualityBuckets[qualityCode] {
                    let explanation: MatchExplanation
                    if directNameRows[rowID] != 0, field != .path, let nameExplanation = cheapIndexedNameExplanation(
                        snapshot: snapshot,
                        rowID: rowID,
                        token: pattern.token,
                        mode: mode
                    ) {
                        explanation = nameExplanation
                    } else {
                        explanation = cheapIndexedPathExplanation(
                            snapshot: snapshot,
                            rowID: rowID,
                            token: pattern.token,
                            mode: mode
                        )
                    }

                    matches.append(SearchMatch(rowID: rowID, score: explanation.score, match: explanation))
                    if matches.count == maxResults {
                        reachedLimit = true
                        break
                    }
                }

                if reachedLimit {
                    break
                }
            }
        } else {
            sortAndLimitMatches()
        }

        let elapsed = Date().timeIntervalSince(started)
        let candidateCount = rowSet.intervals.reduce(0) { $0 + max($1.end - $1.start, 0) }
        return SearchResponse(
            results: materialize(matches, from: snapshot, shouldCancel: shouldCancel),
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

    private static func cheapLiteralNameExplanation(
        snapshot: SearchSnapshot,
        rowID: Int,
        token: String,
        mode: FuzzyMatcher.MatchMode
    ) -> MatchExplanation? {
        guard !token.isEmpty else { return nil }
        guard snapshot.store.normalizedName(at: rowID).contains(token) else { return nil }
        return cheapIndexedNameExplanation(
            snapshot: snapshot,
            rowID: rowID,
            token: token,
            mode: mode
        )
    }

    private static func cheapIndexedNameExplanation(
        snapshot: SearchSnapshot,
        rowID: Int,
        token: String,
        mode: FuzzyMatcher.MatchMode
    ) -> MatchExplanation? {
        guard !token.isEmpty else { return nil }

        let normalizedName = snapshot.store.normalizedName(at: rowID)
        let sourceName = snapshot.store.name(at: rowID)

        if normalizedName == token {
            let score = mode == .exact ? 5_200 : 10_000
            return MatchExplanation(
                matchClass: .exact,
                score: score,
                field: .name,
                reason: "Name exactly matched \"\(token)\""
            )
        }

        if normalizedName.hasPrefix(token) {
            let base = mode == .exact ? 5_200 : 9_200
            let score = base - min(normalizedName.count, 300)
            return MatchExplanation(
                matchClass: .prefix,
                score: score,
                field: .name,
                reason: "Name starts with \"\(token)\""
            )
        }

        if let range = normalizedName.range(of: token) {
            let characterOffset = normalizedName.distance(from: normalizedName.startIndex, to: range.lowerBound)
            let byteOffset = normalizedName[..<range.lowerBound].utf8.count
            let boundaryBonus = isSearchBoundary(
                in: normalizedName,
                sourceText: sourceName,
                atByteOffset: byteOffset
            ) ? (mode == .exact ? 500 : 650) : 0
            let base = mode == .exact ? 5_200 : 7_700
            let offsetPenalty = mode == .exact ? min(characterOffset * 10, 900) : min(characterOffset * 12, 900)
            let score = base + boundaryBonus - offsetPenalty
            return MatchExplanation(
                matchClass: .substring,
                score: score,
                field: .name,
                reason: "Name contains \"\(token)\""
            )
        }

        guard mode == .fuzzy else { return nil }
        return MatchExplanation(
            matchClass: .near,
            score: 5_500,
            field: .name,
            reason: "Name nearly matched \"\(token)\""
        )
    }

    private static func cheapIndexedPathExplanation(
        snapshot: SearchSnapshot,
        rowID: Int,
        token: String,
        mode: FuzzyMatcher.MatchMode
    ) -> MatchExplanation {
        let base = mode == .exact ? 3_900 : 3_500
        return MatchExplanation(
            matchClass: .weakPath,
            score: base,
            field: .ancestorPath,
            reason: "Path ancestor matched \"\(token)\""
        )
    }

    private static func indexedQualityCode(_ quality: MatchQuality) -> UInt8 {
        UInt8(quality.sortRank * 5 + quality.scoreBin)
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

        guard let candidates = unionPostingLists(
            pathCandidates,
            nameCandidates,
            shouldCancel: shouldCancel
        ) else {
            return nil
        }
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
            results: materialize(selected.matches, from: snapshot, shouldCancel: shouldCancel),
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
        guard let candidates = fuzzyNameCandidateIndices(
            snapshot: snapshot,
            tokenBytes: tokenBytes,
            shouldCancel: shouldCancel
        ) else {
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
            if shortFuzzyNameMatches(
                snapshot.store.normalizedName(at: rowID),
                sourceText: snapshot.store.name(at: rowID),
                tokenBytes: tokenBytes
            ) {
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
        let exactNameCandidates = snapshot.candidateNameIndices(
            containing: tokenBytes,
            shouldCancel: shouldCancel
        ) ?? []
        guard !shouldCancel() else { return nil }
        let exactPathCandidates: [Int32]
        var indexesUsed = Set<SearchIndexUse>()
        if field != .path {
            indexesUsed.insert(.nameGrams)
        }
        switch field {
        case .name:
            exactPathCandidates = exactNameCandidates
        case .any, .path:
            let pathCandidates: [Int32]?
            if let gramCandidates = snapshot.candidatePathIndices(containing: tokenBytes) {
                pathCandidates = gramCandidates
                indexesUsed.insert(.pathGrams)
            } else {
                pathCandidates = snapshot.candidatePathIndicesByComponentExpansion(
                    containing: pattern.token,
                    shouldCancel: shouldCancel
                )
                if pathCandidates != nil {
                    indexesUsed.insert(.componentGrams)
                }
            }
            guard let pathCandidates else { return nil }
            if field == .any {
                guard let merged = unionPostingLists(
                    pathCandidates,
                    exactNameCandidates,
                    shouldCancel: shouldCancel
                ) else {
                    return nil
                }
                exactPathCandidates = merged
            } else {
                exactPathCandidates = pathCandidates
            }
        }

        guard exactPathCandidates.count >= max(maxResults, 1) || exactPathCandidates.count > 1_000 else {
            return nil
        }

        if !request.includeHidden {
            indexesUsed.insert(.visibleBitset)
        }

        let candidateMask: UInt8 = 1
        let directNameMask: UInt8 = 2
        let directNameListedMask: UInt8 = 4
        var rowMarkers = Array(repeating: UInt8(0), count: snapshot.count)
        for (offset, candidate) in exactNameCandidates.enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }

            let rowID = Int(candidate)
            guard rowID >= 0, rowID < snapshot.count else { continue }
            rowMarkers[rowID] |= directNameMask
        }

        var candidateRows: [Int] = []
        candidateRows.reserveCapacity(min(exactPathCandidates.count, snapshot.resultCount))
        for (offset, candidate) in exactPathCandidates.enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }

            let rowID = Int(candidate)
            guard rowID >= 0, rowID < snapshot.count else { continue }
            guard snapshot.store.isResultRow(at: rowID) else { continue }
            guard request.includeHidden || snapshot.isVisible(at: rowID) else { continue }
            guard rowMarkers[rowID] & candidateMask == 0 else { continue }
            rowMarkers[rowID] |= candidateMask
            candidateRows.append(rowID)
        }

        guard candidateRows.count >= max(maxResults, 1) || candidateRows.count > 1_000 else {
            return nil
        }

        var directNameRows: [Int] = []
        if field != .path {
            directNameRows.reserveCapacity(min(exactNameCandidates.count, candidateRows.count))
            for (offset, candidate) in exactNameCandidates.enumerated() {
                if offset.isMultiple(of: 512), shouldCancel() {
                    return nil
                }

                let rowID = Int(candidate)
                guard rowID >= 0, rowID < snapshot.count else { continue }
                guard rowMarkers[rowID] & candidateMask != 0 else { continue }
                guard rowMarkers[rowID] & directNameListedMask == 0 else { continue }
                rowMarkers[rowID] |= directNameListedMask
                directNameRows.append(rowID)
            }
        }

        if request.sort.column == .relevance {
            guard let selected = relevanceExactPathSubstringMatches(
                snapshot: snapshot,
                candidateRows: candidateRows,
                rowMarkers: rowMarkers,
                candidateMask: candidateMask,
                directNameMask: directNameMask,
                directNameRows: directNameRows,
                token: pattern.token,
                mode: mode,
                field: field,
                request: request,
                maxResults: maxResults,
                shouldCancel: shouldCancel
            ) else {
                return nil
            }

            let elapsed = Date().timeIntervalSince(started)
            return SearchResponse(
                results: materialize(selected.matches, from: snapshot, shouldCancel: shouldCancel),
                totalMatches: selected.total,
                elapsed: elapsed,
                snapshotRevision: snapshotRevision,
                usesIndexedCandidates: true,
                executionProfile: SearchExecutionProfile(
                    executionPath: .pathGramIndex,
                    indexesUsed: indexesUsed,
                    candidateCount: exactPathCandidates.count,
                    elapsed: elapsed
                )
            )
        }

        if let sortIndexUse = sortedOrderIndexUse(for: request.sort.column),
           let selected = orderedCandidatePreviewSelection(
                snapshot: snapshot,
                request: request,
                maxResults: maxResults,
                total: candidateRows.count,
                shouldCancel: shouldCancel,
                candidateContains: { rowID in
                    rowMarkers[rowID] & candidateMask != 0
                },
                explanation: { rowID in
                    cheapExactPathSubstringExplanation(
                        snapshot: snapshot,
                        rowID: rowID,
                        token: pattern.token,
                        mode: mode,
                        field: field,
                        rowMarkers: rowMarkers,
                        directNameMask: directNameMask
                    )
                }
           ) {
            var sortedIndexesUsed = indexesUsed
            sortedIndexesUsed.insert(sortIndexUse)

            let elapsed = Date().timeIntervalSince(started)
            return SearchResponse(
                results: materialize(selected.matches, from: snapshot, shouldCancel: shouldCancel),
                totalMatches: selected.total,
                elapsed: elapsed,
                snapshotRevision: snapshotRevision,
                usesIndexedCandidates: true,
                executionProfile: SearchExecutionProfile(
                    executionPath: .pathGramIndex,
                    indexesUsed: sortedIndexesUsed,
                    candidateCount: exactPathCandidates.count,
                    scannedRowCount: selected.scannedRowCount,
                    elapsed: elapsed
                )
            )
        }

        guard let selected = exactPathSubstringMatches(
            snapshot: snapshot,
            candidateRows: candidateRows,
            rowMarkers: rowMarkers,
            directNameMask: directNameMask,
            token: pattern.token,
            mode: mode,
            field: field,
            request: request,
            maxResults: maxResults,
            shouldCancel: shouldCancel
        ) else {
            return nil
        }

        let elapsed = Date().timeIntervalSince(started)
        return SearchResponse(
            results: materialize(selected.matches, from: snapshot, shouldCancel: shouldCancel),
            totalMatches: selected.total,
            elapsed: elapsed,
            snapshotRevision: snapshotRevision,
            usesIndexedCandidates: true,
            executionProfile: SearchExecutionProfile(
                executionPath: .pathGramIndex,
                indexesUsed: indexesUsed,
                candidateCount: exactPathCandidates.count,
                elapsed: elapsed
            )
        )
    }

    private static func fastExactExtensionSearch(
        snapshot: SearchSnapshot,
        request: SearchRequest,
        parsedQuery: FuzzyMatcher.ParsedQuery,
        maxResults: Int,
        started: Date,
        snapshotRevision: UInt64,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        guard let candidates = exactExtensionFastPathCandidates(
            snapshot: snapshot,
            parsedQuery: parsedQuery,
            shouldCancel: shouldCancel
        ) else {
            return nil
        }

        guard let selected = exactExtensionMatches(
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
        var indexesUsed: Set<SearchIndexUse> = [.extensionPostings]
        if let sortIndexUse = sortedOrderIndexUse(for: request.sort.column) {
            indexesUsed.insert(sortIndexUse)
        }
        if !request.includeHidden {
            indexesUsed.insert(.visibleBitset)
        }
        return SearchResponse(
            results: materialize(selected.matches, from: snapshot, shouldCancel: shouldCancel),
            totalMatches: selected.total,
            elapsed: elapsed,
            snapshotRevision: snapshotRevision,
            usesIndexedCandidates: true,
            executionProfile: SearchExecutionProfile(
                executionPath: .extensionCandidateIntersection,
                indexesUsed: indexesUsed,
                candidateCount: candidates.count,
                scannedRowCount: selected.scannedRowCount,
                elapsed: elapsed
            )
        )
    }

    private static func exactExtensionFastPathCandidates(
        snapshot: SearchSnapshot,
        parsedQuery: FuzzyMatcher.ParsedQuery,
        shouldCancel: @Sendable () -> Bool
    ) -> [Int32]? {
        guard
            parsedQuery.negative.isEmpty,
            parsedQuery.positive.count == 1,
            let clause = parsedQuery.positive.first,
            !clause.alternatives.isEmpty
        else {
            return nil
        }

        var candidates: [Int32] = []
        var sharedQuality: MatchQuality?
        for alternative in clause.alternatives {
            guard case .fileExtension(let pattern, let mode) = alternative else {
                return nil
            }
            guard
                let extensionCandidates = snapshot.exactExtensionCandidatesForFastPath(
                    token: pattern.token,
                    mode: mode,
                    shouldCancel: shouldCancel
                ),
                let representativeExtension = FuzzyMatcher.exactWildcardLiteralAlternatives(pattern.token)?.first,
                let explanation = FuzzyMatcher.extensionExplanation(representativeExtension, pattern: pattern, mode: mode)
            else {
                return nil
            }

            if let quality = sharedQuality {
                guard quality == explanation.quality else {
                    return nil
                }
            } else {
                sharedQuality = explanation.quality
            }
            guard let merged = unionPostingLists(
                candidates,
                extensionCandidates,
                shouldCancel: shouldCancel
            ) else {
                return nil
            }
            candidates = merged
        }

        return sharedQuality == nil ? nil : candidates
    }

    private struct NameSortedSelection {
        let matches: [SearchMatch]
        let total: Int
        let scannedRowCount: Int

        init(matches: [SearchMatch], total: Int, scannedRowCount: Int = 0) {
            self.matches = matches
            self.total = total
            self.scannedRowCount = scannedRowCount
        }
    }

    private static func sortedOrderIndexUse(for column: SortColumn) -> SearchIndexUse? {
        switch column {
        case .modified:
            return .modifiedOrder
        case .name, .path, .created, .size, .fileExtension, .kind, .volume, .root:
            return .sortOrder
        case .relevance:
            return nil
        }
    }

    private static func orderedCandidatePreviewSelection(
        snapshot: SearchSnapshot,
        request: SearchRequest,
        maxResults: Int,
        total: Int,
        scanLimit: Int? = nil,
        requiresFilledResults: Bool = false,
        optimizedSortColumns: Set<SortColumn> = Set(SortColumn.optimizedIndexColumns),
        shouldCancel: @Sendable () -> Bool,
        candidateContains: (Int) -> Bool,
        explanation: (Int) -> MatchExplanation?
    ) -> NameSortedSelection? {
        guard total > 0 else {
            return NameSortedSelection(matches: [], total: 0)
        }
        guard maxResults > 0 else {
            return NameSortedSelection(matches: [], total: total)
        }
        guard let orderedRows = snapshot.orderedIndices(
            for: request.sort,
            queryIsEmpty: false,
            includeHidden: request.includeHidden,
            optimizedSortColumns: optimizedSortColumns
        ) else {
            return nil
        }

        let targetResultCount = min(maxResults, total)
        let boundedScanLimit = min(orderedRows.count, scanLimit ?? orderedRows.count)
        var matches: [SearchMatch] = []
        matches.reserveCapacity(targetResultCount)
        var scannedRows = 0

        for (offset, rowID) in orderedRows.prefix(boundedScanLimit).enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }

            scannedRows += 1
            guard rowID >= 0, rowID < snapshot.count else { continue }
            guard candidateContains(rowID) else { continue }
            guard snapshot.store.isResultRow(at: rowID) else { continue }
            guard request.includeHidden || snapshot.isVisible(at: rowID) else { continue }
            guard let explanation = explanation(rowID) else { continue }

            matches.append(SearchMatch(rowID: rowID, score: explanation.score, match: explanation))
            if matches.count == targetResultCount {
                break
            }
        }

        guard !shouldCancel() else { return nil }
        if requiresFilledResults, matches.count < targetResultCount {
            return nil
        }
        return NameSortedSelection(matches: matches, total: total, scannedRowCount: scannedRows)
    }

    private static func countResultRows(
        in rowSet: RowIntervalSet,
        snapshot: SearchSnapshot,
        includeHidden: Bool,
        shouldCancel: @Sendable () -> Bool
    ) -> Int? {
        let prefixCounts = includeHidden ? snapshot.resultPrefixCounts : snapshot.visibleResultPrefixCounts
        if prefixCounts.count == snapshot.count + 1 {
            return rowSet.count(using: prefixCounts)
        }

        var total = 0
        for interval in rowSet.intervals {
            for rowID in interval.start..<interval.end {
                if rowID & 511 == 0, shouldCancel() {
                    return nil
                }
                guard rowID >= 0, rowID < snapshot.count else { continue }
                guard snapshot.store.isResultRow(at: rowID) else { continue }
                guard includeHidden || snapshot.isVisible(at: rowID) else { continue }
                total += 1
            }
        }
        return total
    }

    private static func nameSortedComponentPathIntervalMatches(
        snapshot: SearchSnapshot,
        rowSet: RowIntervalSet,
        directNameRows: [UInt8],
        directNameRowIDs: [Int],
        token: String,
        mode: FuzzyMatcher.MatchMode,
        field: FuzzyMatcher.QueryField,
        request: SearchRequest,
        maxResults: Int,
        shouldCancel: @Sendable () -> Bool
    ) -> NameSortedSelection? {
        guard snapshot.hasSortedOrder, !snapshot.nameAscending.isEmpty else {
            return nil
        }

        guard let total = countResultRows(
            in: rowSet,
            snapshot: snapshot,
            includeHidden: request.includeHidden,
            shouldCancel: shouldCancel
        ) else {
            return nil
        }

        guard maxResults > 0, total > 0 else {
            return NameSortedSelection(matches: [], total: total)
        }

        var matches: [SearchMatch] = []
        matches.reserveCapacity(min(maxResults, total))
        let trimThreshold = maxResults * 5
        var scannedRows = 0

        func sortAndLimitMatches() {
            matches.sort {
                compare($0, $1, snapshot: snapshot, sort: request.sort, queryIsEmpty: false)
            }
            if matches.count > maxResults {
                matches.removeSubrange(maxResults..<matches.count)
            }
        }

        for (offset, rowID) in directNameRowIDs.enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }
            scannedRows += 1
            guard rowID >= 0, rowID < snapshot.count else { continue }
            guard snapshot.store.isResultRow(at: rowID) else { continue }
            guard request.includeHidden || snapshot.isVisible(at: rowID) else { continue }
            guard let explanation = cheapIndexedNameExplanation(
                snapshot: snapshot,
                rowID: rowID,
                token: token,
                mode: mode
            ) else {
                continue
            }

            matches.append(SearchMatch(rowID: rowID, score: explanation.score, match: explanation))
            if matches.count > trimThreshold {
                sortAndLimitMatches()
            }
        }

        sortAndLimitMatches()
        guard matches.count < maxResults, field != .name else {
            return NameSortedSelection(matches: matches, total: total, scannedRowCount: scannedRows)
        }

        let order = request.sort.ascending ? snapshot.nameAscending : snapshot.nameDescending
        for (offset, rowID) in order.enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }
            scannedRows += 1
            guard rowID >= 0, rowID < snapshot.count else { continue }
            guard directNameRows[rowID] == 0 else { continue }
            guard rowSet.contains(rowID) else { continue }
            guard snapshot.store.isResultRow(at: rowID) else { continue }
            guard request.includeHidden || snapshot.isVisible(at: rowID) else { continue }

            let explanation = cheapIndexedPathExplanation(
                snapshot: snapshot,
                rowID: rowID,
                token: token,
                mode: mode
            )
            matches.append(SearchMatch(rowID: rowID, score: explanation.score, match: explanation))
            if matches.count == maxResults {
                break
            }
        }

        return NameSortedSelection(matches: matches, total: total, scannedRowCount: scannedRows)
    }

    private static func cheapExactPathSubstringExplanation(
        snapshot: SearchSnapshot,
        rowID: Int,
        token: String,
        mode: FuzzyMatcher.MatchMode,
        field: FuzzyMatcher.QueryField,
        rowMarkers: [UInt8],
        directNameMask: UInt8
    ) -> MatchExplanation? {
        if rowMarkers[rowID] & directNameMask != 0,
           field != .path,
           let nameExplanation = cheapIndexedNameExplanation(
            snapshot: snapshot,
            rowID: rowID,
            token: token,
            mode: mode
        ) {
            return nameExplanation
        }

        guard field != .name else { return nil }
        return cheapIndexedPathExplanation(
            snapshot: snapshot,
            rowID: rowID,
            token: token,
            mode: mode
        )
    }

    private static func exactPathSubstringMatches(
        snapshot: SearchSnapshot,
        candidateRows: [Int],
        rowMarkers: [UInt8],
        directNameMask: UInt8,
        token: String,
        mode: FuzzyMatcher.MatchMode,
        field: FuzzyMatcher.QueryField,
        request: SearchRequest,
        maxResults: Int,
        shouldCancel: @Sendable () -> Bool
    ) -> NameSortedSelection? {
        let total = candidateRows.count
        guard maxResults > 0, total > 0 else {
            return NameSortedSelection(matches: [], total: total)
        }

        var matches: [SearchMatch] = []
        matches.reserveCapacity(min(total, maxResults))
        let trimThreshold = maxResults * 5

        func sortAndLimitMatches() {
            matches.sort {
                compare($0, $1, snapshot: snapshot, sort: request.sort, queryIsEmpty: false)
            }
            if matches.count > maxResults {
                matches.removeSubrange(maxResults..<matches.count)
            }
        }

        for (offset, rowID) in candidateRows.enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }
            guard let explanation = cheapExactPathSubstringExplanation(
                snapshot: snapshot,
                rowID: rowID,
                token: token,
                mode: mode,
                field: field,
                rowMarkers: rowMarkers,
                directNameMask: directNameMask
            ) else {
                continue
            }

            matches.append(SearchMatch(rowID: rowID, score: explanation.score, match: explanation))
            if matches.count > trimThreshold {
                sortAndLimitMatches()
            }
        }

        guard !shouldCancel() else { return nil }
        sortAndLimitMatches()
        return NameSortedSelection(matches: matches, total: total)
    }

    private static func relevanceExactPathSubstringMatches(
        snapshot: SearchSnapshot,
        candidateRows: [Int],
        rowMarkers: [UInt8],
        candidateMask: UInt8,
        directNameMask: UInt8,
        directNameRows: [Int],
        token: String,
        mode: FuzzyMatcher.MatchMode,
        field: FuzzyMatcher.QueryField,
        request: SearchRequest,
        maxResults: Int,
        shouldCancel: @Sendable () -> Bool
    ) -> NameSortedSelection? {
        let total = candidateRows.count
        guard maxResults > 0, total > 0 else {
            return NameSortedSelection(matches: [], total: total)
        }

        guard snapshot.hasSortedOrder, !snapshot.nameAscending.isEmpty else {
            return exactPathSubstringMatches(
                snapshot: snapshot,
                candidateRows: candidateRows,
                rowMarkers: rowMarkers,
                directNameMask: directNameMask,
                token: token,
                mode: mode,
                field: field,
                request: request,
                maxResults: maxResults,
                shouldCancel: shouldCancel
            )
        }

        var matches: [SearchMatch] = []
        matches.reserveCapacity(min(total, maxResults))
        let trimThreshold = maxResults * 5

        func sortAndLimitMatches() {
            matches.sort {
                compare($0, $1, snapshot: snapshot, sort: request.sort, queryIsEmpty: false)
            }
            if matches.count > maxResults {
                matches.removeSubrange(maxResults..<matches.count)
            }
        }

        for (offset, rowID) in directNameRows.enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }
            guard let explanation = cheapIndexedNameExplanation(
                snapshot: snapshot,
                rowID: rowID,
                token: token,
                mode: mode
            ) else {
                continue
            }

            matches.append(SearchMatch(rowID: rowID, score: explanation.score, match: explanation))
            if matches.count > trimThreshold {
                sortAndLimitMatches()
            }
        }

        guard !shouldCancel() else { return nil }
        sortAndLimitMatches()
        guard matches.count < maxResults, field != .name else {
            return NameSortedSelection(matches: matches, total: total)
        }

        for (offset, rowID) in snapshot.nameAscending.enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }
            guard rowMarkers[rowID] & candidateMask != 0 else { continue }
            guard rowMarkers[rowID] & directNameMask == 0 else { continue }

            let explanation = cheapIndexedPathExplanation(
                snapshot: snapshot,
                rowID: rowID,
                token: token,
                mode: mode
            )
            matches.append(SearchMatch(rowID: rowID, score: explanation.score, match: explanation))
            if matches.count == maxResults {
                break
            }
        }

        return NameSortedSelection(matches: matches, total: total)
    }

    private static func exactExtensionMatches(
        snapshot: SearchSnapshot,
        candidates: [Int32],
        parsedQuery: FuzzyMatcher.ParsedQuery,
        request: SearchRequest,
        maxResults: Int,
        shouldCancel: @Sendable () -> Bool
    ) -> NameSortedSelection? {
        guard snapshot.hasSortedOrder, !snapshot.nameAscending.isEmpty || candidates.isEmpty else {
            return nil
        }

        var included = Array(repeating: UInt8(0), count: snapshot.count)
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
            included[rowID] = 1
            total += 1
        }

        guard maxResults > 0, total > 0 else {
            return NameSortedSelection(matches: [], total: total)
        }

        guard request.sort.column == .relevance else {
            let scanLimit = request.mode == .interactivePreview
                ? max(Self.previewOrderedCandidateScanLimit, maxResults * 500)
                : nil
            return orderedCandidatePreviewSelection(
                snapshot: snapshot,
                request: request,
                maxResults: maxResults,
                total: total,
                scanLimit: scanLimit,
                requiresFilledResults: request.mode == .interactivePreview,
                shouldCancel: shouldCancel,
                candidateContains: { rowID in
                    included[rowID] != 0
                },
                explanation: { rowID in
                    FuzzyMatcher.explain(record: snapshot.view(at: rowID), parsedQuery: parsedQuery)
                }
            )
        }

        var matches: [SearchMatch] = []
        matches.reserveCapacity(min(maxResults, total))
        let trimThreshold = max(maxResults * 5, 128)
        var scannedRows = 0

        func sortAndLimitMatches() {
            matches.sort {
                compare($0, $1, snapshot: snapshot, sort: request.sort, queryIsEmpty: false)
            }
            if matches.count > maxResults {
                matches.removeSubrange(maxResults..<matches.count)
            }
        }

        for (offset, candidate) in candidates.enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }

            let rowID = Int(candidate)
            guard rowID >= 0, rowID < snapshot.count else { continue }
            guard included[rowID] != 0 else { continue }
            included[rowID] = 0
            scannedRows += 1
            guard let explanation = FuzzyMatcher.explain(record: snapshot.view(at: rowID), parsedQuery: parsedQuery) else {
                continue
            }
            matches.append(SearchMatch(rowID: rowID, score: explanation.score, match: explanation))
            if matches.count > trimThreshold {
                sortAndLimitMatches()
            }
        }

        guard !shouldCancel() else { return nil }
        sortAndLimitMatches()
        return NameSortedSelection(matches: matches, total: total, scannedRowCount: scannedRows)
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

    private struct NamePreviewCandidate {
        let rowID: Int
        let qualityCode: UInt8
        let normalizedName: String
        let match: MatchExplanation
    }

    private struct RelevancePreviewCandidate {
        let rowID: Int
        let qualityCode: UInt8
        let normalizedName: String
        let match: MatchExplanation
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
            results: materialize(matches, from: snapshot, shouldCancel: shouldCancel),
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
                candidates = intersectPostingLists(current, clauseCandidates, shouldCancel: shouldCancel)
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
            guard let merged = unionPostingLists(
                candidates,
                alternativeCandidates,
                shouldCancel: shouldCancel
            ) else {
                return nil
            }
            candidates = merged
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
            return snapshot.candidateIndices(
                fileExtension: pattern.token,
                mode: mode,
                shouldCancel: shouldCancel
            )
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
                candidates = intersectPostingLists(
                    current,
                    fragmentCandidates,
                    shouldCancel: shouldCancel
                )
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
            return snapshot.candidateNameIndices(containing: fragment, shouldCancel: shouldCancel)
        case .path:
            return pathSubstringCandidateIndices(
                snapshot: snapshot,
                token: String(decoding: fragment, as: UTF8.self),
                shouldCancel: shouldCancel
            )
        case .any:
            guard let nameCandidates = snapshot.candidateNameIndices(
                containing: fragment,
                shouldCancel: shouldCancel
            ) else {
                return nil
            }
            guard let pathCandidates = pathSubstringCandidateIndices(
                snapshot: snapshot,
                token: String(decoding: fragment, as: UTF8.self),
                shouldCancel: shouldCancel
            ) else {
                return nil
            }
            return unionPostingLists(pathCandidates, nameCandidates, shouldCancel: shouldCancel)
        }
    }

    private static func wildcardRequiredFragments(from pattern: String) -> [[UInt8]] {
        let characters = Array(pattern)
        var fragments: [[UInt8]] = []
        var current = ""
        var index = 0

        func flushCurrent() {
            guard !current.isEmpty else { return }
            fragments.append(Array(current.utf8))
            current.removeAll(keepingCapacity: true)
        }

        while index < characters.count {
            let character = characters[index]
            if character == "*" || character == "?" || character == "/" || character == "\\" {
                flushCurrent()
                index += 1
            } else if character == "[" {
                flushCurrent()
                if let nextIndex = wildcardCharacterClassEnd(in: characters, startIndex: index) {
                    index = nextIndex
                } else {
                    current.append(character)
                    index += 1
                }
            } else {
                current.append(character)
                index += 1
            }
        }

        flushCurrent()

        return fragments
    }

    private static func wildcardCharacterClassEnd(in characters: [Character], startIndex: Int) -> Int? {
        var index = startIndex + 1
        guard index < characters.count else { return nil }

        if characters[index] == "!" || characters[index] == "^" {
            index += 1
        }

        var hasMember = false
        while index < characters.count {
            if characters[index] == "]", hasMember {
                return index + 1
            }
            hasMember = true
            index += 1
        }

        return nil
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
            return snapshot.candidateNameIndices(containing: tokenBytes, shouldCancel: shouldCancel)
        case .path:
            return pathSubstringCandidateIndices(
                snapshot: snapshot,
                token: token,
                shouldCancel: shouldCancel
            )
        case .any:
            guard let nameCandidates = snapshot.candidateNameIndices(
                containing: tokenBytes,
                shouldCancel: shouldCancel
            ) else {
                return nil
            }
            guard let pathCandidates = pathSubstringCandidateIndices(
                snapshot: snapshot,
                token: token,
                shouldCancel: shouldCancel
            ) else {
                return nil
            }
            return unionPostingLists(pathCandidates, nameCandidates, shouldCancel: shouldCancel)
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
        let nameCandidates = fuzzyNameCandidateIndices(
            snapshot: snapshot,
            tokenBytes: tokenBytes,
            shouldCancel: shouldCancel
        )

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
            return unionPostingLists(pathCandidates, nameCandidates, shouldCancel: shouldCancel)
        }
    }

    private static func fuzzyNameCandidateIndices(
        snapshot: SearchSnapshot,
        tokenBytes: [UInt8],
        shouldCancel: @Sendable () -> Bool
    ) -> [Int32]? {
        if let candidates = punctuatedFuzzyNameCandidateIndices(
            snapshot: snapshot,
            tokenBytes: tokenBytes,
            shouldCancel: shouldCancel
        ) {
            return candidates
        }

        let distinctBytes = distinctBytes(in: tokenBytes)
        guard !distinctBytes.isEmpty else {
            return nil
        }

        let allowedMissing = tokenBytes.count <= 5 ? 1 : 2
        let requiredCount = max(1, distinctBytes.count - allowedMissing)
        guard requiredCount >= 2 else {
            return snapshot.candidateNameIndices(
                containingAllBytes: distinctBytes,
                shouldCancel: shouldCancel
            )
        }

        guard requiredCount < distinctBytes.count else {
            return snapshot.candidateNameIndices(
                containingAllBytes: distinctBytes,
                shouldCancel: shouldCancel
            )
        }

        let requiredSubsets = byteSubsets(distinctBytes, count: requiredCount)
        guard !requiredSubsets.isEmpty, requiredSubsets.count <= 256 else {
            return nil
        }

        return snapshot.candidateNameIndices(
            containingAny: requiredSubsets,
            shouldCancel: shouldCancel
        )
    }

    private static func punctuatedFuzzyNameCandidateIndices(
        snapshot: SearchSnapshot,
        tokenBytes: [UInt8],
        shouldCancel: @Sendable () -> Bool
    ) -> [Int32]? {
        let separatorCount = tokenBytes.reduce(0) { count, byte in
            count + (isQueryComponentSeparatorByte(byte) ? 1 : 0)
        }
        guard separatorCount > 0 else { return nil }

        guard let exactCandidates = snapshot.candidateNameIndices(
            containing: tokenBytes,
            shouldCancel: shouldCancel
        ) else {
            return nil
        }

        let nonSeparatorBytes = tokenBytes.filter { !isQueryComponentSeparatorByte($0) }
        let distinctNonSeparatorBytes = distinctBytes(in: nonSeparatorBytes)
        guard !distinctNonSeparatorBytes.isEmpty else {
            return exactCandidates
        }

        let typoCandidates = snapshot.candidateNameIndices(
            containingAllBytes: distinctNonSeparatorBytes,
            shouldCancel: shouldCancel
        )
        guard let typoCandidates else { return nil }
        return unionPostingLists(exactCandidates, typoCandidates, shouldCancel: shouldCancel)
    }

    private static func isQueryComponentSeparatorByte(_ byte: UInt8) -> Bool {
        byte == 45 || byte == 46 || byte == 95 || byte == 32
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
        shortFuzzyPathComponentMatches(text, sourceText: text, tokenBytes: tokenBytes)
    }

    private static func shortFuzzyPathComponentMatches(
        _ text: String,
        sourceText: String,
        tokenBytes: [UInt8]
    ) -> Bool {
        guard !tokenBytes.isEmpty else { return false }

        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return false }

        for start in bytes.indices {
            guard !isBoundaryByte(bytes[start]), bytes[start] == tokenBytes[0] else {
                continue
            }

            var tokenIndex = 1
            var lastMatch = start
            var index = start + 1
            while index < bytes.count, !isBoundaryByte(bytes[index]), tokenIndex < tokenBytes.count {
                if bytes[index] == tokenBytes[tokenIndex] {
                    lastMatch = index
                    tokenIndex += 1
                }
                index += 1
            }

            guard tokenIndex == tokenBytes.count else {
                continue
            }

            let spanWidth = lastMatch - start + 1
            if
                spanWidth <= tokenBytes.count + 1
                    || isSearchBoundary(in: text, sourceText: sourceText, atByteOffset: start)
                    || isSearchBoundary(in: text, sourceText: sourceText, atByteOffset: lastMatch)
            {
                return true
            }
        }

        return false
    }

    private static func shortFuzzyNameMatches(_ text: String, tokenBytes: [UInt8]) -> Bool {
        shortFuzzyNameMatches(text, sourceText: text, tokenBytes: tokenBytes)
    }

    private static func shortFuzzyNameMatches(_ text: String, sourceText: String, tokenBytes: [UInt8]) -> Bool {
        guard !tokenBytes.isEmpty else { return false }
        if shortFuzzyPathComponentMatches(text, sourceText: sourceText, tokenBytes: tokenBytes) {
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

    private static func intersectPostingLists(
        _ postings: [[Int32]],
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> [Int32]? {
        guard var result = postings.first else {
            return []
        }

        for posting in postings.dropFirst() {
            guard !shouldCancel() else { return nil }
            if result.isEmpty {
                break
            }
            guard let intersection = intersectPostingLists(result, posting, shouldCancel: shouldCancel) else {
                return nil
            }
            result = intersection
        }

        return result
    }

    private static func intersectPostingLists(
        _ lhs: [Int32],
        _ rhs: [Int32],
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> [Int32]? {
        var result: [Int32] = []
        result.reserveCapacity(min(lhs.count, rhs.count))

        var leftIndex = 0
        var rightIndex = 0
        var comparisonCount = 0

        while leftIndex < lhs.count, rightIndex < rhs.count {
            if comparisonCount & 255 == 0, shouldCancel() {
                return nil
            }
            comparisonCount += 1
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

    private static func unionPostingLists(
        _ lhs: [Int32],
        _ rhs: [Int32],
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> [Int32]? {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }

        var result: [Int32] = []
        result.reserveCapacity(lhs.count + rhs.count)

        var leftIndex = 0
        var rightIndex = 0
        var comparisonCount = 0

        while leftIndex < lhs.count, rightIndex < rhs.count {
            if comparisonCount & 255 == 0, shouldCancel() {
                return nil
            }
            comparisonCount += 1
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

        while leftIndex < lhs.count {
            if leftIndex & 255 == 0, shouldCancel() {
                return nil
            }
            result.append(lhs[leftIndex])
            leftIndex += 1
        }

        while rightIndex < rhs.count {
            if rightIndex & 255 == 0, shouldCancel() {
                return nil
            }
            result.append(rhs[rightIndex])
            rightIndex += 1
        }

        return result
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

    private static func isSearchBoundary(in text: String, sourceText: String, atByteOffset offset: Int) -> Bool {
        guard offset > 0 else { return true }

        let bytes = Array(text.utf8)
        if offset <= bytes.count, isBoundaryByte(bytes[offset - 1]) {
            return true
        }

        guard sourceText.utf8.allSatisfy({ $0 < 128 }) else {
            return false
        }

        let sourceCharacters = Array(sourceText)
        guard offset > 0, offset < sourceCharacters.count else {
            return false
        }

        let previous = sourceCharacters[offset - 1]
        let current = sourceCharacters[offset]
        if isComponentSeparator(previous) {
            return true
        }

        let previousScalar = String(previous).unicodeScalars.first
        let currentScalar = String(current).unicodeScalars.first
        let nextScalar = offset + 1 < sourceCharacters.count
            ? String(sourceCharacters[offset + 1]).unicodeScalars.first
            : nil
        let previousIsLowerOrDigit = previousScalar.map {
            CharacterSet.lowercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0)
        } ?? false
        let previousIsUpper = previousScalar.map { CharacterSet.uppercaseLetters.contains($0) } ?? false
        let currentIsUpper = currentScalar.map { CharacterSet.uppercaseLetters.contains($0) } ?? false
        let nextIsLower = nextScalar.map { CharacterSet.lowercaseLetters.contains($0) } ?? false
        return (previousIsLowerOrDigit && currentIsUpper) || (previousIsUpper && currentIsUpper && nextIsLower)
    }

    private static func isComponentSeparator(_ character: Character) -> Bool {
        character == "/" || character == "\\" || character == "-" || character == "_" || character == "." || character == " "
    }

    public func deleteSnapshot() {
        lock.withLock {
            recordsByPath.removeAll(keepingCapacity: true)
            clearOptimizedSearchFallbackWithoutLock()
            searchSnapshot = .empty
            searchSnapshotRevision &+= 1
            status = "Index deleted"
            indexing = false
            reconciling = false
            updating = false
            activityPresentation = .foreground
            clearActiveReconciliationWithoutLock()
            phase = .idle
            discoveredCount = 0
            searchableCount = 0
            optimizedCount = 0
            lastUpdated = Date()
            activeOperationStartedAt = nil
            lastCheckpointAt = nil
            resumedFromCheckpoint = false
            persistRevision &+= 1
        }
        try? fileManager.removeItem(at: snapshotURL)
        try? structuralDeltaStore.clear()
        lock.withLock {
            structuralDelta = nil
            clearStructuralDeltaCompactionWithoutLock()
        }
        removeScanCheckpoint()
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
            reconciling = false
            updating = false
            activityPresentation = .foreground
            clearActiveReconciliationWithoutLock()
            phase = .loading
            status = "Loading saved index"
            lastUpdated = Date()
            activeOperationStartedAt = nil
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

        let started = Date()
        DiagnosticLogger.shared.log(category: "index", event: "index.snapshotLoadBegin")
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
                reconciling = false
                updating = false
                discoveredCount = 0
                searchableCount = 0
                optimizedCount = 0
                lastUpdated = Date()
                activeOperationStartedAt = nil
                resumedFromCheckpoint = false
                return true
            }

            if didUpdate {
                publishStats()
            }
            DiagnosticLogger.shared.log(
                category: "index",
                event: "index.snapshotLoadNoPersistedSnapshot",
                fields: [
                    "durationSeconds": .publicDouble(Date().timeIntervalSince(started))
                ]
            )
            return
        }

        let metrics = RecordCollectionMetrics(recordCount: persisted.store.count, totalPathBytes: 0, maxPathBytes: 0)
        let baseSnapshot = SearchSnapshot(
            store: persisted.store,
            persistedStructures: persisted.searchStructures,
            optimizedSortColumns: currentOptimizedSortColumns()
        )
        let currentExclusionPatterns = lock.withLock { exclusionRules.patterns }
        let loadedStructuralSnapshot: LoadedStructuralSnapshot
        if persisted.manifest.exclusionPatterns == currentExclusionPatterns {
            let metadataSnapshot = loadPersistedMetadataOverlay(
                baseSnapshot: baseSnapshot,
                manifest: persisted.manifest
            )
            loadedStructuralSnapshot = loadPersistedStructuralDelta(
                baseSnapshot: metadataSnapshot,
                manifest: persisted.manifest
            )
        } else {
            discardPersistedMetadataOverlay(reason: "settingsMismatch")
            try? structuralDeltaStore.clear()
            loadedStructuralSnapshot = LoadedStructuralSnapshot(
                snapshot: baseSnapshot,
                delta: nil,
                optimizedFallback: nil,
                compositeSearchState: nil,
                requiresFullReconciliation: false
            )
        }
        let snapshot = loadedStructuralSnapshot.snapshot
        let loadedOptimized = snapshot.isOptimizedForSearch
            || loadedStructuralSnapshot.compositeSearchState != nil
        MemoryTelemetry.log(
            "snapshot.load.mapped",
            records: metrics,
            structures: snapshot.diagnostics,
            activeIndexJobs: currentActiveIndexJobCount()
        )
        var didLoadUsableSnapshot = false
        var shouldRemoveCheckpointForSettingsChange = false
        let didApply = lock.withLock { () -> Bool in
            guard generation == generationAtStart else {
                return false
            }

            guard persisted.manifest.exclusionPatterns == exclusionRules.patterns else {
                snapshotLoadState = .finished
                phase = .idle
                status = "Index settings changed"
                indexing = false
                reconciling = false
                updating = false
                discoveredCount = 0
                searchableCount = 0
                optimizedCount = 0
                lastUpdated = Date()
                activeOperationStartedAt = nil
                resumedFromCheckpoint = false
                shouldRemoveCheckpointForSettingsChange = true
                return true
            }

            self.recordsByPath.removeAll(keepingCapacity: false)
            if let optimizedFallback = loadedStructuralSnapshot.optimizedFallback {
                rememberOptimizedSearchFallbackWithoutLock(optimizedFallback)
            }
            searchSnapshot = snapshot
            compositeSearchState = loadedStructuralSnapshot.compositeSearchState
            structuralDelta = loadedStructuralSnapshot.delta
            searchSnapshotRevision &+= 1
            roots = persisted.manifest.roots
            snapshotLoadState = .finished
            phase = .ready
            status = "Loaded \(snapshot.resultCount) indexed files"
            indexing = false
            reconciling = false
            updating = false
            self.discoveredCount = snapshot.resultCount
            searchableCount = snapshot.resultCount
            optimizedCount = loadedOptimized ? snapshot.resultCount : 0
            lastUpdated = persisted.manifest.savedAt
            activeOperationStartedAt = nil
            resumedFromCheckpoint = false
            didLoadUsableSnapshot = true
            return true
        }

        if didApply {
            publishStats()
        }

        if shouldRemoveCheckpointForSettingsChange {
            removeScanCheckpoint()
        }

        if didApply, didLoadUsableSnapshot {
            removeSupersededScanCheckpoint(finalSavedAt: persisted.manifest.savedAt)
            DiagnosticLogger.shared.log(
                category: "index",
                event: "index.snapshotLoadApplied",
                fields: [
                    "recordCount": .publicInt(snapshot.resultCount),
                    "rootCount": .publicInt(persisted.manifest.roots.count),
                    "optimizedForSearch": .publicBool(loadedOptimized),
                    "modifiedOrderCount": .publicInt(snapshot.modifiedDescending.count),
                    "visibleModifiedOrderCount": .publicInt(snapshot.visibleModifiedDescending.count),
                    "nameGramPostingCount": .publicInt(snapshot.diagnostics.nameGramPostingCount),
                    "componentGramPostingCount": .publicInt(snapshot.diagnostics.componentGramPostingCount),
                    "pathGramPostingCount": .publicInt(snapshot.diagnostics.pathGramPostingCount),
                    "durationSeconds": .publicDouble(Date().timeIntervalSince(started))
                ],
                diagnosticFields: [
                    "roots": .pathArray(persisted.manifest.roots)
                ]
            )
            MemoryTelemetry.log(
                "snapshot.load.applied",
                records: metrics,
                structures: snapshot.diagnostics,
                activeIndexJobs: currentActiveIndexJobCount()
            )

            if loadedStructuralSnapshot.requiresFullReconciliation {
                reconcileIndexedRootsInBackground(activityPresentation: .foreground)
                indexQueue.async { [weak self] in
                    guard let self else { return }
                    let stats = self.currentStats()
                    guard stats.phase == .ready, stats.status.hasPrefix("Reconciled") else { return }
                    self.requestBackgroundReconciliation()
                }
            } else if loadedStructuralSnapshot.delta != nil {
                requestBackgroundReconciliation()
                scheduleStructuralDeltaCompactionIfNeeded(snapshot)
            } else if !loadedOptimized {
                indexQueue.async { [weak self] in
                    self?.optimizeLoadedSnapshot(generation: generationAtStart)
                }
            } else {
                requestBackgroundReconciliation()
            }
        }
    }

    private func rebuild(roots rootURLs: [URL], mode: RebuildMode, generation currentGeneration: UInt64, started: Date) {
        let maintenanceMeasurement = MaintenanceMeasurement(startedAt: started)
        let jobID = beginIndexJob("rebuild")
        defer { endIndexJob("rebuild", jobID: jobID) }

        let exclusions = lock.withLock { exclusionRules }
        let rootPaths = rootURLs.map(\.path)
        let checkpoint: LoadedScanCheckpoint?
        let operationStartedAt: Date
        if mode == .resumeIfAvailable {
            checkpoint = loadResumableScanCheckpoint(roots: rootPaths, exclusionPatterns: exclusions.patterns)
            operationStartedAt = checkpoint?.state.operationStartedAt ?? started
            if let checkpoint {
                applyLoadedScanCheckpoint(checkpoint, generation: currentGeneration)
            }
        } else {
            removeScanCheckpoint()
            checkpoint = nil
            operationStartedAt = started
        }

        let publishPrimary: @Sendable (_ store: HeapPagedRecordStore, _ visited: Int, _ force: Bool) -> Void = { [weak self] store, visited, _ in
            self?.publishPrimarySnapshot(store, visited: visited, generation: currentGeneration)
        }

        MemoryTelemetry.log("rebuild.scan.begin", activeIndexJobs: currentActiveIndexJobCount())
        DiagnosticLogger.shared.log(
            category: "index",
            event: "index.rebuildBegin",
            fields: [
                "mode": .publicString(Self.diagnosticRebuildModeString(mode)),
                "rootCount": .publicInt(rootPaths.count),
                "resumedFromCheckpoint": .publicBool(checkpoint != nil),
                "workerCount": .publicInt(Self.scanWorkerCount())
            ],
            diagnosticFields: [
                "roots": .pathArray(rootPaths)
            ]
        )

        guard let scanResult = scanConcurrently(
            roots: rootURLs,
            exclusions: exclusions,
            generation: currentGeneration,
            checkpoint: checkpoint,
            operationStartedAt: operationStartedAt,
            workerCount: Self.scanWorkerCount(),
            workerQoS: .utility,
            progress: publishPrimary
        ) else {
            let cancelled = !isCurrentGeneration(currentGeneration)
            DiagnosticLogger.shared.log(
                level: cancelled ? .warning : .error,
                category: "index",
                event: cancelled ? "index.rebuildCancelled" : "index.rebuildFailed",
                fields: [
                    "mode": .publicString(Self.diagnosticRebuildModeString(mode)),
                    "durationSeconds": .publicDouble(Date().timeIntervalSince(started))
                ]
            )
            if !cancelled {
                failIndexing(
                    "Could not read the filesystem while building the index.",
                    generation: currentGeneration
                )
            }
            return
        }

        guard isCurrentGeneration(currentGeneration) else { return }
        recordScanFrontierMetrics(scanResult.frontierMetrics, generation: currentGeneration)
        guard let scanStore = scanResult.store else {
            failIndexing("Could not build scan store.", generation: currentGeneration)
            return
        }
        let publishesIntermediateSnapshots = shouldPublishSearchableSnapshotsDuringScan()
        if publishesIntermediateSnapshots {
            publishPrimary(scanStore, scanResult.visited, true)
        }
        optimizeAndPublish(
            initialStore: scanStore,
            generation: currentGeneration,
            publishesIntermediateSnapshots: publishesIntermediateSnapshots,
            operationStartedAt: started,
            memoryTelemetryContext: MemoryTelemetryContext(scopeCount: rootURLs.count, reconcilesAllRoots: true)
        )
        guard isCurrentGeneration(currentGeneration) else { return }
        recordFullRebuild(duration: Date().timeIntervalSince(started))
        recordMaintenance(maintenanceMeasurement.operation(
            kind: .fullRebuild,
            priority: .interactive,
            paths: rootURLs.count,
            records: scanResult.recordCount,
            visited: scanResult.visited,
            exclusionInstrumentation: scanResult.exclusionInstrumentation
        ))
        DiagnosticLogger.shared.log(
            category: "index",
            event: "index.rebuildFinished",
            fields: [
                "mode": .publicString(Self.diagnosticRebuildModeString(mode)),
                "recordCount": .publicInt(scanResult.recordCount),
                "visitedCount": .publicInt(scanResult.visited),
                "durationSeconds": .publicDouble(Date().timeIntervalSince(started))
            ]
        )
    }

    private func reconcile(
        roots rootURLs: [URL],
        allRootPaths: [String],
        exclusions: FileExclusionRules,
        generation currentGeneration: UInt64,
        started: Date,
        activityPresentation: IndexActivityPresentation
    ) {
        let maintenanceMeasurement = MaintenanceMeasurement(startedAt: started)
        let jobID = beginIndexJob("reconcile")
        defer { endIndexJob("reconcile", jobID: jobID) }

        let scannedRootPaths = rootURLs.map(\.path)
        let reconcilesAllRoots = Set(scannedRootPaths) == Set(allRootPaths)
        let telemetryContext = MemoryTelemetryContext(
            scopeCount: rootURLs.count,
            reconcilesAllRoots: reconcilesAllRoots
        )
        let previousSnapshot = lock.withLock { searchSnapshot }
        let previousStore = previousSnapshot.store
        MemoryTelemetry.log(
            "reconcile.previousStore.ready",
            records: Self.countOnlyMetrics(for: previousStore),
            store: previousStore,
            activeIndexJobs: currentActiveIndexJobCount(),
            context: telemetryContext
        )

        MemoryTelemetry.log(
            "reconcile.scan.begin",
            activeIndexJobs: currentActiveIndexJobCount(),
            context: telemetryContext
        )
        DiagnosticLogger.shared.log(
            category: "index",
            event: "index.reconcileBegin",
            fields: [
                "reconcilesAllRoots": .publicBool(reconcilesAllRoots),
                "activityPresentation": .publicString(activityPresentation.rawValue),
                "scopeCount": .publicInt(rootURLs.count),
                "workerCount": .publicInt(Self.refreshScanWorkerCount())
            ],
            diagnosticFields: [
                "scopes": .pathArray(scannedRootPaths)
            ]
        )
        guard let scanResult = scanConcurrently(
            roots: rootURLs,
            exclusions: exclusions,
            generation: currentGeneration,
            checkpoint: nil,
            operationStartedAt: started,
            exclusionRootPaths: allRootPaths,
            writesCheckpoints: false,
            publishesScanStatus: true,
            publishesIntermediateSnapshots: false,
            buildsRecordStore: previousSnapshot.count == 0,
            reconciliationBaselineStore: previousSnapshot.count == 0 ? nil : previousStore,
            throttlesWhenBackgrounded: true,
            workerCount: Self.refreshScanWorkerCount(),
            workerQoS: .utility,
            progress: { _, _, _ in }
        ) else {
            let cancelled = !isCurrentGeneration(currentGeneration)
            DiagnosticLogger.shared.log(
                level: cancelled ? .warning : .error,
                category: "index",
                event: cancelled ? "index.reconcileCancelled" : "index.reconcileFailed",
                fields: [
                    "durationSeconds": .publicDouble(Date().timeIntervalSince(started))
                ]
            )
            if !cancelled {
                failIndexing(
                    "Could not read the filesystem while reconciling the index.",
                    generation: currentGeneration
                )
            }
            return
        }

        guard isCurrentGeneration(currentGeneration) else { return }
        recordScanFrontierMetrics(scanResult.frontierMetrics, generation: currentGeneration)
        let scanMetrics = scanResult.store.map { Self.countOnlyMetrics(for: $0) }
            ?? RecordCollectionMetrics(
                recordCount: scanResult.recordCount,
                totalPathBytes: 0,
                maxPathBytes: 0
            )
        MemoryTelemetry.log(
            "reconcile.scan.finished",
            records: scanMetrics,
            store: scanResult.store,
            activeIndexJobs: currentActiveIndexJobCount(),
            context: telemetryContext
        )
        if previousSnapshot.count == 0 {
            guard let scanStore = scanResult.store else {
                failIndexing("Could not build reconciliation store.", generation: currentGeneration)
                return
            }
            MemoryTelemetry.log(
                "reconcile.fullRoot.recordsReady",
                records: Self.countOnlyMetrics(for: scanStore),
                store: scanStore,
                activeIndexJobs: currentActiveIndexJobCount(),
                context: telemetryContext
            )
            optimizeAndPublish(
                initialStore: scanStore,
                generation: currentGeneration,
                publishesIntermediateSnapshots: false,
                completionStatusPrefix: activityPresentation == .backgroundCatchUp ? "Caught up" : "Reconciled",
                operationStartedAt: started,
                memoryTelemetryContext: telemetryContext
            )
        } else {
            guard let reconciliationDelta = scanResult.reconciliationDelta else {
                failIndexing("Could not build reconciliation delta.", generation: currentGeneration)
                return
            }
            guard applyReconciliationDelta(
                previousSnapshot: previousSnapshot,
                scannedRootPaths: scannedRootPaths,
                scanDelta: reconciliationDelta,
                generation: currentGeneration,
                completionStatusPrefix: activityPresentation == .backgroundCatchUp ? "Caught up" : "Reconciled",
                operationStartedAt: started,
                memoryTelemetryContext: telemetryContext
            ) else {
                return
            }
        }
        guard isCurrentGeneration(currentGeneration) else { return }
        recordFullRebuild(duration: Date().timeIntervalSince(started))
        let finalRecordCount = lock.withLock { searchSnapshot.resultCount }
        recordMaintenance(maintenanceMeasurement.operation(
            kind: .reconcile,
            priority: activityPresentation == .backgroundCatchUp ? .background : .interactive,
            paths: rootURLs.count,
            records: finalRecordCount,
            visited: scanResult.visited,
            yieldedSlices: scanResult.yieldedSlices,
            exclusionInstrumentation: scanResult.exclusionInstrumentation
        ))
        DiagnosticLogger.shared.log(
            category: "index",
            event: "index.reconcileFinished",
            fields: [
                "recordCount": .publicInt(finalRecordCount),
                "visitedCount": .publicInt(scanResult.visited),
                "durationSeconds": .publicDouble(Date().timeIntervalSince(started))
            ]
        )
    }

    private func applyReconciliationDelta(
        previousSnapshot: SearchSnapshot,
        scannedRootPaths: [String],
        scanDelta: ReconciliationScanDelta,
        generation currentGeneration: UInt64,
        completionStatusPrefix: String,
        operationStartedAt: Date,
        memoryTelemetryContext: MemoryTelemetryContext
    ) -> Bool {
        let upserts = scanDelta.upserts

        let reconcilesAllRows = Set(scannedRootPaths) == Set(lock.withLock { roots })
        var deletedRows = Set<Int>()
        func collectMissingRows<Rows: Sequence>(in rows: Rows) -> Bool where Rows.Element == Int {
            for rowID in rows {
                if rowID.isMultiple(of: 4_096), !isCurrentGeneration(currentGeneration) {
                    return false
                }
                guard previousSnapshot.store.isResultRow(at: rowID) else { continue }
                if !scanDelta.observedBaselineRows.contains(rowID) {
                    deletedRows.insert(rowID)
                }
            }
            return true
        }

        if reconcilesAllRows {
            guard collectMissingRows(in: 0..<previousSnapshot.count) else { return false }
        } else {
            for scope in scannedRootPaths {
                if let rows = previousSnapshot.store.rowIDs(inSubtreeAtPath: scope) {
                    guard collectMissingRows(in: rows) else { return false }
                    continue
                }

                for rowID in 0..<previousSnapshot.count {
                    if rowID.isMultiple(of: 4_096), !isCurrentGeneration(currentGeneration) {
                        return false
                    }
                    guard previousSnapshot.store.isResultRow(at: rowID) else { continue }
                    let path = previousSnapshot.store.path(at: rowID)
                    if (path == scope || path.hasPrefix(scope + "/")),
                       !scanDelta.observedBaselineRows.contains(rowID) {
                        deletedRows.insert(rowID)
                    }
                }
            }
        }

        guard isCurrentGeneration(currentGeneration) else { return false }
        if upserts.isEmpty, deletedRows.isEmpty {
            if lock.withLock({ hasUnpersistedSnapshotChanges }) {
                let priority: IndexMaintenancePriority = activityPresentation == .backgroundCatchUp
                    ? .background
                    : .interactive
                guard persistSnapshot(
                    schedulesPathGramBuild: false,
                    priority: priority
                ) else {
                    return false
                }
            }

            let completedSnapshot = lock.withLock { searchSnapshot }
            let didFinish = lock.withLock { () -> Bool in
                guard generation == currentGeneration else { return false }
                indexing = false
                reconciling = false
                updating = false
                clearActiveReconciliationWithoutLock()
                phase = .ready
                discoveredCount = completedSnapshot.resultCount
                searchableCount = completedSnapshot.resultCount
                optimizedCount = completedSnapshot.isOptimizedForSearch ? completedSnapshot.resultCount : 0
                status = Self.completionStatus(
                    prefix: completionStatusPrefix,
                    recordCount: completedSnapshot.resultCount,
                    startedAt: operationStartedAt
                )
                lastUpdated = Date()
                activeOperationStartedAt = nil
                return true
            }
            if didFinish {
                publishStats()
                DiagnosticLogger.shared.log(
                    category: "index",
                    event: "index.reconcileDeltaNoop",
                    fields: [
                        "scannedRecordCount": .publicInt(scanDelta.recordCount),
                        "reconciledScopeCount": .publicInt(scannedRootPaths.count),
                        "durationSeconds": .publicDouble(Date().timeIntervalSince(operationStartedAt))
                    ]
                )
            }
            return didFinish
        }

        let tombstonedPaths = deletedRows.map { previousSnapshot.store.path(at: $0) }
        for path in upserts.keys {
            if let rowID = previousSnapshot.store.rowID(forPath: path) {
                deletedRows.insert(rowID)
            }
        }
        let overlayStore = OverlayRecordStore(
            base: previousSnapshot.store,
            upserts: Array(upserts.values),
            deletedRows: deletedRows
        )
        let snapshot = SearchSnapshot(
            store: overlayStore,
            buildsSearchStructures: false,
            buildsPathGramIndex: false,
            optimizedSortColumns: currentOptimizedSortColumns(),
            buildsAdditionalSortOrders: false,
            prefersDegradedSearch: true
        )
        let compositeInputs = lock.withLock {
            (
                previousState: compositeSearchState,
                optimizedBase: compositeSearchState?.base.sourceSnapshot
                    ?? optimizedSearchFallbackSnapshot,
                roots: roots
            )
        }
        let indexedCompositeState = makeCompositeSearchState(
            logicalSnapshot: snapshot,
            optimizedBase: compositeInputs.optimizedBase,
            roots: compositeInputs.roots,
            previousState: compositeInputs.previousState,
            changedUpserts: Array(upserts.values),
            changedTombstonedPaths: tombstonedPaths
        )
        let persistenceResult = persistStructuralDeltaChanges(
            upserts: Array(upserts.values),
            tombstonedPaths: tombstonedPaths,
            previousSnapshot: previousSnapshot
        )
        guard isCurrentGeneration(currentGeneration) else { return false }
        let durableSnapshot: SearchSnapshot
        let durableCompositeState: CompositeSearchState?
        switch persistenceResult {
        case .saved:
            durableSnapshot = snapshot
            durableCompositeState = indexedCompositeState
        case .unavailable:
            do {
                durableSnapshot = try persistStandaloneReconciliationSnapshot(snapshot)
                durableCompositeState = nil
            } catch {
                failIndexing(
                    "Could not save reconciled changes: \(error.localizedDescription)",
                    generation: currentGeneration
                )
                return false
            }
        case .failed:
            failIndexing(
                "Could not save reconciled changes: The structural delta could not be saved.",
                generation: currentGeneration
            )
            return false
        }

        let changedPathCount = upserts.count + tombstonedPaths.count
        let didApply = lock.withLock { () -> Bool in
            guard generation == currentGeneration else { return false }
            searchSnapshot = durableSnapshot
            compositeSearchState = durableCompositeState
            searchSnapshotRevision &+= 1
            indexing = false
            reconciling = false
            updating = false
            clearActiveReconciliationWithoutLock()
            phase = .ready
            discoveredCount = durableSnapshot.resultCount
            searchableCount = durableSnapshot.resultCount
            optimizedCount = durableSnapshot.isOptimizedForSearch || durableCompositeState != nil
                ? durableSnapshot.resultCount
                : 0
            status = Self.completionStatus(
                prefix: completionStatusPrefix,
                recordCount: durableSnapshot.resultCount,
                startedAt: operationStartedAt
            )
            recordsByPath.removeAll(keepingCapacity: false)
            lastUpdated = Date()
            activeOperationStartedAt = nil
            completedSnapshotRebuilds &+= 1
            return true
        }
        guard didApply else { return false }

        publishStats()
        if persistenceResult == .saved {
            scheduleStructuralDeltaCompactionIfNeeded(durableSnapshot)
        }
        MemoryTelemetry.log(
            "reconcile.delta.applied",
            records: Self.countOnlyMetrics(for: durableSnapshot.store),
            structures: durableSnapshot.diagnostics,
            store: durableSnapshot.store,
            activeIndexJobs: currentActiveIndexJobCount(),
            context: memoryTelemetryContext
        )
        DiagnosticLogger.shared.log(
            category: "index",
            event: "index.reconcileDeltaApplied",
            fields: [
                "changedPathCount": .publicInt(changedPathCount),
                "upsertCount": .publicInt(upserts.count),
                "tombstoneCount": .publicInt(tombstonedPaths.count),
                "durable": .publicBool(true),
                "durationSeconds": .publicDouble(Date().timeIntervalSince(operationStartedAt))
            ]
        )
        return true
    }

    private func persistStandaloneReconciliationSnapshot(
        _ snapshot: SearchSnapshot
    ) throws -> SearchSnapshot {
        let settings = lock.withLock {
            (
                roots: roots,
                exclusionPatterns: exclusionRules.patterns,
                optimizedSortColumns: optimizedSortColumns
            )
        }
        var persistedSnapshot: SearchSnapshot?
        _ = try persistMappedSnapshot(
            roots: settings.roots,
            exclusionPatterns: settings.exclusionPatterns,
            store: snapshot.store
        ) { mappedStore, packageURL in
            let rebasedSnapshot = snapshot.rebasedForMappedPersistence(
                store: mappedStore,
                completePathGramIndex: nil,
                optimizedSortColumns: settings.optimizedSortColumns
            )
            try persistSearchStructures(for: rebasedSnapshot, packageURL: packageURL)
            persistedSnapshot = rebasedSnapshot
        }
        guard let persistedSnapshot else {
            throw CocoaError(.fileWriteUnknown)
        }
        return persistedSnapshot
    }

    private func scanConcurrently(
        roots rootURLs: [URL],
        exclusions: FileExclusionRules,
        generation currentGeneration: UInt64,
        checkpoint: LoadedScanCheckpoint?,
        operationStartedAt: Date,
        exclusionRootPaths: [String]? = nil,
        writesCheckpoints: Bool = true,
        publishesScanStatus: Bool = true,
        publishesIntermediateSnapshots: Bool = true,
        buildsRecordStore: Bool = true,
        reconciliationBaselineStore: RecordStore? = nil,
        throttlesWhenBackgrounded: Bool = false,
        workerCount: Int,
        workerQoS: DispatchQoS.QoSClass,
        progress: @escaping @Sendable (_ store: HeapPagedRecordStore, _ visited: Int, _ force: Bool) -> Void
    ) -> ScanResult? {
        let rootPaths = rootURLs.map(\.path)
        let ruleRootPaths = exclusionRootPaths ?? rootPaths
        let scanConfiguration = lock.withLock {
            (
                evaluationMode: exclusionEvaluationMode,
                frontierMode: scanFrontierMode,
                frontierBatchSize: scanFrontierBatchSize
            )
        }
        let rootPreflightExclusionQuery = makeExclusionQuery(
            exclusions: exclusions,
            rootPaths: ruleRootPaths,
            evaluationMode: scanConfiguration.evaluationMode
        )
        let exclusionInstrumentationAccumulator = ExclusionInstrumentationAccumulator()
        let claimBatchSize = scanConfiguration.frontierMode.usesBatchedClaim
            ? max(scanConfiguration.frontierBatchSize, 1)
            : 1
        let usesBatchedEnqueue = scanConfiguration.frontierMode.usesBatchedEnqueue
        let currentCount = buildsRecordStore ? lock.withLock { searchSnapshot.count } : 0
        let state = ConcurrentScanState(
            reservedCapacity: max(8_192, currentCount, checkpoint?.store.count ?? 0),
            roots: rootPaths,
            existingRecords: checkpoint?.store.allRecords() ?? [],
            pendingDirectories: checkpoint?.state.resumableDirectories
                .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? [],
            completedDirectories: Set(checkpoint?.state.completedDirectories ?? []),
            operationStartedAt: operationStartedAt,
            lastCheckpointCount: checkpoint?.state.recordCount ?? 0,
            lastCheckpointAt: checkpoint?.state.savedAt,
            buildsRecordStore: buildsRecordStore,
            reconciliationBaselineStore: reconciliationBaselineStore,
            tracksCompletedDirectories: writesCheckpoints,
            onTerminalState: { [weak self] in
                self?.wakeBackgroundReconciliation()
            }
        )

        let publish: @Sendable (_ result: ScanProgress?, _ force: Bool) -> Void = { result, force in
            guard let result else { return }
            progress(result.store, result.visited, force)
        }
        let publishSearchableSnapshot: @Sendable (_ force: Bool) -> Void = { [weak self] force in
            guard publishesIntermediateSnapshots else { return }
            guard self?.shouldPublishSearchableSnapshotsDuringScan() ?? true else {
                return
            }
            publish(state.publishSnapshotIfNeeded(force: force), force)
        }
        let publishStatus: @Sendable (_ visited: Int?) -> Void = { [weak self] visited in
            guard publishesScanStatus, let self, let visited else { return }
            self.publishScanStatus(visited: visited, generation: currentGeneration)
        }

        let checkpointProgress: @Sendable (_ result: ScanCheckpointProgress?, _ force: Bool) -> Void = { [weak self] result, force in
            guard writesCheckpoints, let self, let result else { return }
            if force {
                self.persistScanCheckpoint(
                    result,
                    roots: rootPaths,
                    exclusionPatterns: exclusions.patterns,
                    generation: currentGeneration
                )
            } else {
                self.persistScanCheckpointAsync(
                    result,
                    roots: rootPaths,
                    exclusionPatterns: exclusions.patterns,
                    generation: currentGeneration
                )
            }
        }
        let recordBackgroundYield: @Sendable (TimeInterval) -> Void = { [weak self] delay in
            state.recordYieldedSlice()
            self?.recordMaintenance(IndexMaintenanceOperationMetric(
                kind: .backgroundSlice,
                priority: .background,
                yieldedSlices: 1,
                deferredPaths: 1
            ))
            DiagnosticLogger.shared.log(
                category: "index",
                event: "index.backgroundReconciliationSlice",
                fields: [
                    "delaySeconds": .publicDouble(delay),
                    "workerCount": .publicInt(workerCount)
                ]
            )
        }

        if checkpoint == nil {
            let rootVolumeNameCache = ScanVolumeNameCache()
            var rootInstrumentation = FileExclusionQuery.Instrumentation()
            for root in rootURLs {
                let rootCandidate: FileSystemRecordCandidate
                switch retryingFileSystemRecordLookup(for: root, volumeNameCache: rootVolumeNameCache) {
                case .record(let candidate):
                    rootCandidate = candidate
                case .missing:
                    logSkippedRoot(root, reason: "missing")
                    continue
                case .retry(let error):
                    logFullScanTraversalFailure(path: root.path, error: error)
                    return nil
                }
                guard rootCandidate.isDirectory || rootCandidate.isSymlink else {
                    logSkippedRoot(root, reason: "notDirectory")
                    continue
                }
                let rootDecision = exclusionDecision(
                    for: root,
                    exclusions: exclusions,
                    rootPaths: ruleRootPaths,
                    query: rootPreflightExclusionQuery,
                    isDirectory: rootCandidate.isDirectory,
                    instrumentation: &rootInstrumentation
                )
                guard rootDecision != .prune else {
                    logSkippedRoot(root, reason: "excluded")
                    continue
                }
                if rootDecision.shouldIndex {
                    state.addInitialRecord(rootCandidate.record)
                }
                if rootCandidate.isDirectory, !rootCandidate.isSymlink, rootDecision.shouldDescend {
                    state.enqueue(root)
                }
            }
            exclusionInstrumentationAccumulator.add(rootInstrumentation)
        }

        let workers = DispatchGroup()
        let workerQueue = DispatchQueue.global(qos: workerQoS)

        for _ in 0..<workerCount {
            workers.enter()
            workerQueue.async { [weak self] in
                defer { workers.leave() }
                guard let self else {
                    state.markStopped()
                    return
                }
                let workerExclusionQuery = self.makeExclusionQuery(
                    exclusions: exclusions,
                    rootPaths: ruleRootPaths,
                    evaluationMode: scanConfiguration.evaluationMode
                )
                var workerInstrumentation = FileExclusionQuery.Instrumentation()
                defer {
                    exclusionInstrumentationAccumulator.add(workerInstrumentation)
                }
                let volumeNameCache = ScanVolumeNameCache()
                var backgroundSliceStartedAt = Date()
                var recordsSinceThrottleCheck = 0

                var batch: [FileRecord] = []
                batch.reserveCapacity(256)

                scanLoop: while true {
                    guard self.pauseBackgroundReconciliationIfNeeded(
                        enabled: throttlesWhenBackgrounded,
                        generation: currentGeneration,
                        workerCount: workerCount,
                        sliceStartedAt: &backgroundSliceStartedAt,
                        isStoppedOrComplete: state.isStoppedOrComplete,
                        onYield: recordBackgroundYield
                    ) else {
                        if !state.isComplete() {
                            state.markStopped()
                        }
                        break
                    }
                    let directories = state.nextDirectories(maxCount: claimBatchSize)
                    guard !directories.isEmpty else { break }

                    var finishedDirectories: [URL] = []
                    finishedDirectories.reserveCapacity(directories.count)

                    for directory in directories {
                        guard self.isCurrentGeneration(currentGeneration) else {
                            finishedDirectories.append(directory)
                            state.finishDirectories(finishedDirectories)
                            state.markStopped()
                            break scanLoop
                        }

                        var childDirectories: [URL] = []
                        var childLookupRetryError: Int32?
                        if usesBatchedEnqueue {
                            childDirectories.reserveCapacity(32)
                        }

                        let enumerationResult = self.enumerateShallowChildURLs(
                            in: directory,
                            prunesDirectoryNamed: { name in
                                let prunes = exclusions.canPruneDirectoryComponentBeforeStat(name)
                                if prunes {
                                    workerInstrumentation.fastPruneDirectoryCount += 1
                                }
                                return prunes
                            }
                        ) { child in
                            if !self.isCurrentGeneration(currentGeneration) {
                                state.markStopped()
                                return false
                            }
                            recordsSinceThrottleCheck += 1
                            if recordsSinceThrottleCheck >= 256 {
                                recordsSinceThrottleCheck = 0
                                guard self.pauseBackgroundReconciliationIfNeeded(
                                    enabled: throttlesWhenBackgrounded,
                                    generation: currentGeneration,
                                    workerCount: workerCount,
                                    sliceStartedAt: &backgroundSliceStartedAt,
                                    isStoppedOrComplete: state.isStoppedOrComplete,
                                    onYield: recordBackgroundYield
                                ) else {
                                    if !state.isComplete() {
                                        state.markStopped()
                                    }
                                    return false
                                }
                            }

                            autoreleasepool {
                                let candidate: FileSystemRecordCandidate
                                switch self.retryingFileSystemRecordLookup(
                                    for: child,
                                    volumeNameCache: volumeNameCache
                                ) {
                                case .record(let recordCandidate):
                                    candidate = recordCandidate
                                case .missing:
                                    return
                                case .retry(let error):
                                    childLookupRetryError = error
                                    return
                                }
                                let decision = self.exclusionDecision(
                                    for: candidate.url,
                                    exclusions: exclusions,
                                    rootPaths: ruleRootPaths,
                                    query: workerExclusionQuery,
                                    isDirectory: candidate.isDirectory,
                                    instrumentation: &workerInstrumentation
                                )
                                guard decision != .prune else { return }
                                guard !(candidate.isDirectory && candidate.isSymlink) else {
                                    return
                                }

                                if decision.shouldIndex {
                                    batch.append(candidate.record)
                                }

                                if candidate.isDirectory, decision.shouldDescend {
                                    if usesBatchedEnqueue {
                                        childDirectories.append(child)
                                    } else {
                                        state.enqueue(child)
                                    }
                                }
                            }

                            if childLookupRetryError != nil {
                                return false
                            }
                            if batch.count >= 256 {
                                state.append(batch)
                                batch.removeAll(keepingCapacity: true)
                                publishStatus(state.statusIfNeeded(force: false))
                                publishSearchableSnapshot(false)
                                checkpointProgress(state.checkpointIfNeeded(force: false), false)
                            }
                            return true
                        }

                        switch enumerationResult {
                        case .completed:
                            break
                        case .stopped:
                            if let childLookupRetryError {
                                self.logFullScanTraversalFailure(
                                    path: directory.path,
                                    error: childLookupRetryError
                                )
                            }
                            state.finishDirectories(finishedDirectories)
                            state.markStopped()
                            break scanLoop
                        case .retry(let error):
                            self.logFullScanTraversalFailure(path: directory.path, error: error)
                            state.finishDirectories(finishedDirectories)
                            state.markStopped()
                            break scanLoop
                        }

                        if usesBatchedEnqueue {
                            state.enqueue(contentsOf: childDirectories)
                        }

                        if !batch.isEmpty {
                            state.append(batch)
                            batch.removeAll(keepingCapacity: true)
                            publishStatus(state.statusIfNeeded(force: false))
                            publishSearchableSnapshot(false)
                            checkpointProgress(state.checkpointIfNeeded(force: false), false)
                        }

                        finishedDirectories.append(directory)
                    }

                    state.finishDirectories(finishedDirectories)
                }
            }
        }

        workers.wait()
        publishStatus(state.statusIfNeeded(force: true))

        let (result, wasStopped) = state.result(
            exclusionInstrumentation: exclusionInstrumentationAccumulator.snapshot()
        )
        return wasStopped ? nil : result
    }

    private func shouldPublishSearchableSnapshotsDuringScan() -> Bool {
        lock.withLock {
            publishesSearchableSnapshotsDuringScan
        }
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
            reconciling = false
            updating = false
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
                records: Self.countOnlyMetrics(for: snapshot.store),
                structures: snapshot.diagnostics,
                activeIndexJobs: currentActiveIndexJobCount()
            )
        }
    }

    private func publishScanStatus(visited: Int, generation currentGeneration: UInt64) {
        let didApply = lock.withLock { () -> Bool in
            guard generation == currentGeneration, indexing, phase == .scanning else {
                return false
            }

            discoveredCount = visited
            if activityPresentation == .backgroundCatchUp, reconciling {
                status = "Catching up changes"
            } else {
                let verb = reconciling ? "Reconciling" : "Indexing"
                status = "\(verb) \(discoveredCount.formatted()) discovered"
            }
            lastUpdated = Date()
            return true
        }

        if didApply {
            publishStats()
        }
    }

    private func publishReadySnapshotAndOptimizeInBackground(
        initialStore: HeapPagedRecordStore,
        generation currentGeneration: UInt64,
        completionStatusPrefix: String,
        operationStartedAt: Date?,
        memoryTelemetryContext: MemoryTelemetryContext
    ) {
        let snapshot = SearchSnapshot(store: initialStore, buildsSearchStructures: false)
        let snapshotSettings = lock.withLock {
            (
                roots: roots,
                exclusionPatterns: exclusionRules.patterns,
                shouldReconcileAfterFinish: resumedFromCheckpoint && completionStatusPrefix == "Indexed",
                usesExternalReconciliationHandler: backgroundReconciliationHandler != nil
            )
        }

        var readySnapshotRevision: UInt64?
        let didFinish = lock.withLock { () -> Bool in
            guard generation == currentGeneration else {
                return false
            }

            self.recordsByPath.removeAll(keepingCapacity: false)
            searchSnapshot = snapshot
            searchSnapshotRevision &+= 1
            readySnapshotRevision = searchSnapshotRevision
            indexing = false
            if reconciling {
                clearActiveReconciliationWithoutLock()
            }
            reconciling = false
            updating = false
            phase = .ready
            self.discoveredCount = snapshot.resultCount
            searchableCount = snapshot.resultCount
            optimizedCount = 0
            status = Self.completionStatus(
                prefix: completionStatusPrefix,
                recordCount: snapshot.resultCount,
                startedAt: operationStartedAt
            )
            lastUpdated = Date()
            activeOperationStartedAt = nil
            resumedFromCheckpoint = false
            completedSnapshotRebuilds &+= 1
            hasUnpersistedSnapshotChanges = true
            unpersistedSnapshotRevision = searchSnapshotRevision
            durabilityRetryAttempt = 0
            durabilityRetryScheduled = false
            durabilityRetryGeneration &+= 1
            return true
        }

        guard didFinish else { return }
        publishStats()
        MemoryTelemetry.log(
            "rebuild.primary.ready",
            records: Self.countOnlyMetrics(for: snapshot.store),
            structures: snapshot.diagnostics,
            store: snapshot.store,
            activeIndexJobs: currentActiveIndexJobCount(),
            context: memoryTelemetryContext
        )
        if snapshotSettings.shouldReconcileAfterFinish,
           !snapshotSettings.usesExternalReconciliationHandler {
            requestBackgroundReconciliation()
            return
        }
        recordDeferredOptimization(reason: "largeRebuild", delay: 0)
        optimizeAndPersistSnapshotInBackground(
            store: initialStore,
            roots: snapshotSettings.roots,
            exclusionPatterns: snapshotSettings.exclusionPatterns,
            generation: currentGeneration,
            baseSnapshotRevision: readySnapshotRevision ?? 0,
            memoryTelemetryContext: memoryTelemetryContext
        )
        if snapshotSettings.shouldReconcileAfterFinish {
            requestBackgroundReconciliation()
        }
    }

    private func optimizeAndPersistSnapshotInBackground(
        store: RecordStore,
        roots: [String],
        exclusionPatterns: [String],
        generation currentGeneration: UInt64,
        baseSnapshotRevision: UInt64,
        memoryTelemetryContext: MemoryTelemetryContext
    ) {
        let didRegister = lock.withLock { () -> Bool in
            guard generation == currentGeneration,
                  searchSnapshotRevision == baseSnapshotRevision,
                  activeDeferredOptimizationRevision == nil else {
                return false
            }
            activeDeferredOptimizationRevision = baseSnapshotRevision
            return true
        }
        guard didRegister else {
            markReadySnapshotDurabilityPendingIfNeeded()
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let jobID = self.beginIndexJob("deferredOptimize")
            defer {
                self.endIndexJob("deferredOptimize", jobID: jobID)
                self.lock.withLock {
                    if self.activeDeferredOptimizationRevision == baseSnapshotRevision {
                        self.activeDeferredOptimizationRevision = nil
                    }
                }
            }

            let started = Date()
            let maintenanceMeasurement = MaintenanceMeasurement(startedAt: started)
            let recordCount = store.storedResultCount ?? store.count
            let estimatedMetrics = RecordCollectionMetrics(
                recordCount: recordCount,
                totalPathBytes: 0,
                maxPathBytes: 0
            )
            func logCancellation(reason: String) {
                let generationMatches = self.isCurrentGeneration(currentGeneration)
                let snapshotRevisionMatches = self.isSnapshotRevisionCurrent(baseSnapshotRevision)
                DiagnosticLogger.shared.log(
                    category: "index",
                    event: "index.deferredOptimizationCancelled",
                    fields: [
                        "reason": .publicString(reason),
                        "recordCount": .publicInt(recordCount),
                        "durationSeconds": .publicDouble(Date().timeIntervalSince(started)),
                        "generationMatches": .publicBool(generationMatches),
                        "snapshotRevisionMatches": .publicBool(snapshotRevisionMatches)
                    ]
                )
                self.markReadySnapshotDurabilityPendingIfNeeded()
            }

            guard self.isCurrentGeneration(currentGeneration),
                  self.isSnapshotRevisionCurrent(baseSnapshotRevision)
            else {
                logCancellation(reason: "staleBeforeBuild")
                return
            }

            let packageURL = SnapshotLayout.temporaryPackageURL(in: self.supportDirectory)
            func cancelIfStale(_ reason: String) -> Bool {
                guard self.isCurrentGeneration(currentGeneration),
                      self.isSnapshotRevisionCurrent(baseSnapshotRevision) else {
                    try? self.fileManager.removeItem(at: packageURL)
                    logCancellation(reason: reason)
                    return true
                }
                return false
            }

            do {
                MemoryTelemetry.log(
                    "rebuild.deferredOptimize.mappedWrite.begin",
                    records: estimatedMetrics,
                    activeIndexJobs: self.currentActiveIndexJobCount(),
                    context: memoryTelemetryContext
                )
                try MappedRecordStore.writePackage(
                    recordSource: RecordPackageRecordSource(
                        estimatedRecordCount: recordCount,
                        enumerateRecords: store.forEachResultRecord
                    ),
                    roots: roots,
                    exclusionPatterns: exclusionPatterns,
                    packageURL: packageURL,
                    fileManager: self.fileManager
                )
                guard !cancelIfStale("staleAfterPackageWrite") else { return }
                MemoryTelemetry.log(
                    "rebuild.deferredOptimize.mappedWrite.end",
                    records: estimatedMetrics,
                    activeIndexJobs: self.currentActiveIndexJobCount(),
                    context: memoryTelemetryContext
                )
                let mappedStore = try MappedRecordStore(
                    packageURL: packageURL,
                    schemaVersion: SnapshotLayout.schemaVersion
                )
                guard !cancelIfStale("staleAfterMappedLoad") else { return }
                MemoryTelemetry.log(
                    "rebuild.deferredOptimize.mappedStore.loaded",
                    records: Self.countOnlyMetrics(for: mappedStore),
                    store: mappedStore,
                    activeIndexJobs: self.currentActiveIndexJobCount(),
                    context: memoryTelemetryContext
                )
                var optimizedSnapshot = SearchSnapshot(store: mappedStore, buildsSearchStructures: false)
                MemoryTelemetry.log(
                    "rebuild.deferredOptimize.snapshot.mapped",
                    records: Self.countOnlyMetrics(for: optimizedSnapshot.store),
                    structures: optimizedSnapshot.diagnostics,
                    store: optimizedSnapshot.store,
                    activeIndexJobs: self.currentActiveIndexJobCount(),
                    context: memoryTelemetryContext
                )
                MemoryTelemetry.log(
                    "rebuild.deferredOptimize.nameGrams.begin",
                    records: Self.countOnlyMetrics(for: optimizedSnapshot.store),
                    store: optimizedSnapshot.store,
                    activeIndexJobs: self.currentActiveIndexJobCount(),
                    context: memoryTelemetryContext
                )
                optimizedSnapshot = optimizedSnapshot.addingNameGramIndex()
                guard !cancelIfStale("staleAfterNameIndex") else { return }
                MemoryTelemetry.log(
                    "rebuild.deferredOptimize.nameGrams.end",
                    records: Self.countOnlyMetrics(for: optimizedSnapshot.store),
                    structures: optimizedSnapshot.diagnostics,
                    store: optimizedSnapshot.store,
                    activeIndexJobs: self.currentActiveIndexJobCount(),
                    context: memoryTelemetryContext
                )
                MemoryTelemetry.log(
                    "rebuild.deferredOptimize.extensions.begin",
                    records: Self.countOnlyMetrics(for: optimizedSnapshot.store),
                    structures: optimizedSnapshot.diagnostics,
                    store: optimizedSnapshot.store,
                    activeIndexJobs: self.currentActiveIndexJobCount(),
                    context: memoryTelemetryContext
                )
                optimizedSnapshot = optimizedSnapshot.addingExtensionIndex()
                guard !cancelIfStale("staleAfterExtensionIndex") else { return }
                MemoryTelemetry.log(
                    "rebuild.deferredOptimize.extensions.end",
                    records: Self.countOnlyMetrics(for: optimizedSnapshot.store),
                    structures: optimizedSnapshot.diagnostics,
                    store: optimizedSnapshot.store,
                    activeIndexJobs: self.currentActiveIndexJobCount(),
                    context: memoryTelemetryContext
                )
                MemoryTelemetry.log(
                    "rebuild.deferredOptimize.modifiedSort.begin",
                    records: Self.countOnlyMetrics(for: optimizedSnapshot.store),
                    structures: optimizedSnapshot.diagnostics,
                    store: optimizedSnapshot.store,
                    activeIndexJobs: self.currentActiveIndexJobCount(),
                    context: memoryTelemetryContext
                )
                optimizedSnapshot = optimizedSnapshot.addingModifiedSortOrder()
                guard !cancelIfStale("staleAfterModifiedSort") else { return }
                MemoryTelemetry.log(
                    "rebuild.deferredOptimize.modifiedSort.end",
                    records: Self.countOnlyMetrics(for: optimizedSnapshot.store),
                    structures: optimizedSnapshot.diagnostics,
                    store: optimizedSnapshot.store,
                    activeIndexJobs: self.currentActiveIndexJobCount(),
                    context: memoryTelemetryContext
                )

                guard !cancelIfStale("staleAfterBuild") else { return }

                MemoryTelemetry.log(
                    "rebuild.deferredOptimize.persistSearchStructures.begin",
                    records: Self.countOnlyMetrics(for: optimizedSnapshot.store),
                    structures: optimizedSnapshot.diagnostics,
                    store: optimizedSnapshot.store,
                    activeIndexJobs: self.currentActiveIndexJobCount(),
                    context: memoryTelemetryContext
                )
                try self.persistSearchStructures(for: optimizedSnapshot, packageURL: packageURL)
                MemoryTelemetry.log(
                    "rebuild.deferredOptimize.persistSearchStructures.end",
                    records: Self.countOnlyMetrics(for: optimizedSnapshot.store),
                    structures: optimizedSnapshot.diagnostics,
                    store: optimizedSnapshot.store,
                    activeIndexJobs: self.currentActiveIndexJobCount(),
                    context: memoryTelemetryContext
                )

                guard !cancelIfStale("staleAfterPersist") else { return }

                MemoryTelemetry.log(
                    "rebuild.deferredOptimize.installMappedSnapshot.begin",
                    records: Self.countOnlyMetrics(for: optimizedSnapshot.store),
                    structures: optimizedSnapshot.diagnostics,
                    store: optimizedSnapshot.store,
                    activeIndexJobs: self.currentActiveIndexJobCount(),
                    context: memoryTelemetryContext
                )
                var installError: Error?
                let didApply = self.lock.withLock { () -> Bool in
                    guard self.generation == currentGeneration,
                          self.searchSnapshotRevision == baseSnapshotRevision else {
                        return false
                    }

                    do {
                        try self.replaceMappedSnapshotPackageOnDisk(packageURL)
                    } catch {
                        installError = error
                        return false
                    }
                    self.structuralDelta = nil
                    self.clearStructuralDeltaCompactionWithoutLock()
                    self.clearSnapshotDurabilityPendingWithoutLock()
                    self.searchSnapshot = optimizedSnapshot
                    self.searchSnapshotRevision &+= 1
                    self.optimizedCount = optimizedSnapshot.isOptimizedForSearch ? optimizedSnapshot.resultCount : 0
                    self.lastUpdated = Date()
                    return true
                }
                if let installError {
                    throw installError
                }
                guard didApply else {
                    try? self.fileManager.removeItem(at: packageURL)
                    logCancellation(reason: "staleBeforeInstall")
                    return
                }
                self.finishMappedSnapshotInstallation()
                MemoryTelemetry.log(
                    "rebuild.deferredOptimize.installMappedSnapshot.end",
                    records: Self.countOnlyMetrics(for: optimizedSnapshot.store),
                    structures: optimizedSnapshot.diagnostics,
                    store: optimizedSnapshot.store,
                    activeIndexJobs: self.currentActiveIndexJobCount(),
                    context: memoryTelemetryContext
                )

                self.publishStats()
                self.clearDeferredOptimizationMarker()
                self.recordMaintenance(maintenanceMeasurement.operation(
                    kind: .optimization,
                    priority: .background,
                    records: optimizedSnapshot.resultCount
                ))
                let appliedRevision = self.lock.withLock { self.searchSnapshotRevision }
                self.startPathGramBuildIfNeeded(
                    snapshot: optimizedSnapshot,
                    packageURL: self.snapshotURL,
                    generation: currentGeneration,
                    baseSnapshotRevision: appliedRevision
                )
                MemoryTelemetry.log(
                    "rebuild.deferredOptimized.applied",
                    records: Self.countOnlyMetrics(for: optimizedSnapshot.store),
                    structures: optimizedSnapshot.diagnostics,
                    store: optimizedSnapshot.store,
                    activeIndexJobs: self.currentActiveIndexJobCount(),
                    context: memoryTelemetryContext
                )
                DiagnosticLogger.shared.log(
                    category: "index",
                    event: "index.deferredOptimizationFinished",
                    fields: [
                        "recordCount": .publicInt(optimizedSnapshot.resultCount),
                        "durationSeconds": .publicDouble(Date().timeIntervalSince(started))
                    ]
                )
            } catch {
                try? self.fileManager.removeItem(at: packageURL)
                self.recordPersistFailure()
                self.markReadySnapshotDurabilityPendingIfNeeded()
                DiagnosticLogger.shared.log(
                    level: .error,
                    category: "index",
                    event: "index.deferredOptimizationFailed",
                    fields: [
                        "recordCount": .publicInt(recordCount),
                        "durationSeconds": .publicDouble(Date().timeIntervalSince(started)),
                        "error": .errorText(error.localizedDescription)
                    ]
                )
            }
        }
    }

    private static func scopedMergedRecordSource(
        previousStore: RecordStore,
        scannedRootPaths: [String],
        scanRecords: [String: FileRecord]
    ) -> RecordPackageRecordSource {
        let retainedEstimate = previousStore.storedResultCount ?? previousStore.count
        return RecordPackageRecordSource(estimatedRecordCount: retainedEstimate + scanRecords.count) { emit in
            previousStore.forEachResultRecord { record in
                guard !Self.path(record.path, isContainedIn: scannedRootPaths) else { return }
                emit(record)
            }
            for record in scanRecords.values {
                emit(record)
            }
        }
    }

    private func optimizeScopedMergeAndPublish(
        previousStore: RecordStore,
        scannedRootPaths: [String],
        scanRecords: [String: FileRecord],
        generation currentGeneration: UInt64,
        completionStatusPrefix: String,
        operationStartedAt: Date?,
        memoryTelemetryContext: MemoryTelemetryContext
    ) {
        let recordSource = Self.scopedMergedRecordSource(
            previousStore: previousStore,
            scannedRootPaths: scannedRootPaths,
            scanRecords: scanRecords
        )
        let estimatedMetrics = RecordCollectionMetrics(
            recordCount: recordSource.estimatedRecordCount,
            totalPathBytes: 0,
            maxPathBytes: 0
        )
        MemoryTelemetry.log(
            "reconcile.merge.streamSource.ready",
            records: estimatedMetrics,
            store: previousStore,
            activeIndexJobs: currentActiveIndexJobCount(),
            context: memoryTelemetryContext
        )

        guard isCurrentGeneration(currentGeneration) else { return }
        publishRebuildStatus(
            phase: .optimizing,
            status: "Optimizing compact store",
            discovered: recordSource.estimatedRecordCount,
            searchable: lock.withLock { searchSnapshot.resultCount },
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
            MemoryTelemetry.log(
                "optimize.mappedWrite.begin",
                records: estimatedMetrics,
                store: previousStore,
                activeIndexJobs: currentActiveIndexJobCount(),
                context: memoryTelemetryContext
            )
            try MappedRecordStore.writePackage(
                recordSource: recordSource,
                roots: snapshotSettings.roots,
                exclusionPatterns: snapshotSettings.exclusionPatterns,
                packageURL: packageURL,
                fileManager: fileManager
            )
            MemoryTelemetry.log(
                "optimize.mappedWrite.end",
                records: estimatedMetrics,
                store: previousStore,
                activeIndexJobs: currentActiveIndexJobCount(),
                context: memoryTelemetryContext
            )
            let mappedStore = try MappedRecordStore(packageURL: packageURL, schemaVersion: SnapshotLayout.schemaVersion)
            MemoryTelemetry.log(
                "optimize.mappedStore.loaded",
                records: Self.countOnlyMetrics(for: mappedStore),
                store: mappedStore,
                activeIndexJobs: currentActiveIndexJobCount(),
                context: memoryTelemetryContext
            )
            optimizeMappedPackageAndPublish(
                mappedStore: mappedStore,
                packageURL: packageURL,
                discoveredCount: recordSource.estimatedRecordCount,
                generation: currentGeneration,
                publishesIntermediateSnapshots: false,
                completionStatusPrefix: completionStatusPrefix,
                operationStartedAt: operationStartedAt,
                memoryTelemetryContext: memoryTelemetryContext
            )
        } catch {
            failIndexing("Could not build compact index: \(error.localizedDescription)", generation: currentGeneration)
            return
        }
    }

    private func optimizeAndPublish(
        initialStore: HeapPagedRecordStore,
        generation currentGeneration: UInt64,
        publishesIntermediateSnapshots: Bool = true,
        completionStatusPrefix: String = "Indexed",
        operationStartedAt: Date? = nil,
        memoryTelemetryContext: MemoryTelemetryContext = .none
    ) {
        let recordCount = initialStore.storedResultCount ?? initialStore.count
        let deferredOptimizationThreshold = lock.withLock {
            deferredOptimizationRecordThreshold
        }
        if recordCount >= deferredOptimizationThreshold, publishesIntermediateSnapshots {
            publishReadySnapshotAndOptimizeInBackground(
                initialStore: initialStore,
                generation: currentGeneration,
                completionStatusPrefix: completionStatusPrefix,
                operationStartedAt: operationStartedAt,
                memoryTelemetryContext: memoryTelemetryContext
            )
            return
        }

        let recordSource = RecordPackageRecordSource(
            estimatedRecordCount: recordCount,
            enumerateRecords: initialStore.forEachResultRecord
        )
        let estimatedMetrics = RecordCollectionMetrics(
            recordCount: recordCount,
            totalPathBytes: 0,
            maxPathBytes: 0
        )
        MemoryTelemetry.log(
            "optimize.records.streamSource.ready",
            records: estimatedMetrics,
            store: initialStore,
            activeIndexJobs: currentActiveIndexJobCount(),
            context: memoryTelemetryContext
        )

        let snapshot = SearchSnapshot(store: initialStore, buildsSearchStructures: false)
        MemoryTelemetry.log(
            "optimize.primarySnapshot.created",
            records: Self.countOnlyMetrics(for: snapshot.store),
            structures: snapshot.diagnostics,
            store: snapshot.store,
            activeIndexJobs: currentActiveIndexJobCount(),
            context: memoryTelemetryContext
        )

        guard isCurrentGeneration(currentGeneration) else { return }
        let searchableBeforeOptimization = lock.withLock { searchSnapshot.resultCount }
        publishRebuildStatus(
            phase: .optimizing,
            status: "Optimizing compact store",
            discovered: recordCount,
            searchable: publishesIntermediateSnapshots ? recordCount : searchableBeforeOptimization,
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
            MemoryTelemetry.log(
                "optimize.mappedWrite.begin",
                records: estimatedMetrics,
                store: snapshot.store,
                activeIndexJobs: currentActiveIndexJobCount(),
                context: memoryTelemetryContext
            )
            try MappedRecordStore.writePackage(
                recordSource: recordSource,
                roots: snapshotSettings.roots,
                exclusionPatterns: snapshotSettings.exclusionPatterns,
                packageURL: packageURL,
                fileManager: fileManager
            )
            MemoryTelemetry.log(
                "optimize.mappedWrite.end",
                records: estimatedMetrics,
                store: snapshot.store,
                activeIndexJobs: currentActiveIndexJobCount(),
                context: memoryTelemetryContext
            )
            let mappedStore = try MappedRecordStore(packageURL: packageURL, schemaVersion: SnapshotLayout.schemaVersion)
            MemoryTelemetry.log(
                "optimize.mappedStore.loaded",
                records: Self.countOnlyMetrics(for: mappedStore),
                store: mappedStore,
                activeIndexJobs: currentActiveIndexJobCount(),
                context: memoryTelemetryContext
            )
            optimizeMappedPackageAndPublish(
                mappedStore: mappedStore,
                packageURL: packageURL,
                discoveredCount: recordCount,
                generation: currentGeneration,
                publishesIntermediateSnapshots: publishesIntermediateSnapshots,
                completionStatusPrefix: completionStatusPrefix,
                operationStartedAt: operationStartedAt,
                memoryTelemetryContext: memoryTelemetryContext
            )
        } catch {
            failIndexing("Could not build compact index: \(error.localizedDescription)", generation: currentGeneration)
            return
        }
    }

    private func optimizeMappedPackageAndPublish(
        mappedStore: MappedRecordStore,
        packageURL pendingMappedPackageURL: URL,
        discoveredCount: Int,
        generation currentGeneration: UInt64,
        publishesIntermediateSnapshots: Bool,
        completionStatusPrefix: String,
        operationStartedAt: Date?,
        memoryTelemetryContext: MemoryTelemetryContext
    ) {
        var snapshot = SearchSnapshot(store: mappedStore, buildsSearchStructures: false)
        MemoryTelemetry.log(
            "optimize.mappedSnapshot.created",
            records: Self.countOnlyMetrics(for: snapshot.store),
            structures: snapshot.diagnostics,
            store: snapshot.store,
            activeIndexJobs: currentActiveIndexJobCount(),
            context: memoryTelemetryContext
        )
        if publishesIntermediateSnapshots {
            publishOptimizedSnapshot(
                snapshot,
                status: "Optimizing names",
                optimized: 0,
                generation: currentGeneration
            )
        }

        MemoryTelemetry.log(
            "optimize.nameGrams.begin",
            records: Self.countOnlyMetrics(for: snapshot.store),
            store: snapshot.store,
            activeIndexJobs: currentActiveIndexJobCount(),
            context: memoryTelemetryContext
        )
        snapshot = snapshot.addingNameGramIndex()
        MemoryTelemetry.log(
            "optimize.nameGrams.end",
            records: Self.countOnlyMetrics(for: snapshot.store),
            structures: snapshot.diagnostics,
            store: snapshot.store,
            activeIndexJobs: currentActiveIndexJobCount(),
            context: memoryTelemetryContext
        )
        if publishesIntermediateSnapshots {
            publishOptimizedSnapshot(
                snapshot,
                status: "Optimizing extensions",
                optimized: 0,
                generation: currentGeneration
            )
        } else {
            publishRebuildStatus(
                phase: .optimizing,
                status: "Optimizing extensions",
                discovered: discoveredCount,
                searchable: lock.withLock { searchSnapshot.resultCount },
                optimized: 0,
                isIndexing: true,
                generation: currentGeneration
            )
        }

        guard isCurrentGeneration(currentGeneration) else { return }
        MemoryTelemetry.log(
            "optimize.extensions.begin",
            records: Self.countOnlyMetrics(for: snapshot.store),
            structures: snapshot.diagnostics,
            store: snapshot.store,
            activeIndexJobs: currentActiveIndexJobCount(),
            context: memoryTelemetryContext
        )
        snapshot = snapshot.addingExtensionIndex()
        MemoryTelemetry.log(
            "optimize.extensions.end",
            records: Self.countOnlyMetrics(for: snapshot.store),
            structures: snapshot.diagnostics,
            store: snapshot.store,
            activeIndexJobs: currentActiveIndexJobCount(),
            context: memoryTelemetryContext
        )
        if publishesIntermediateSnapshots {
            publishOptimizedSnapshot(
                snapshot,
                status: "Optimizing modified sort",
                optimized: 0,
                generation: currentGeneration
            )
        } else {
            publishRebuildStatus(
                phase: .optimizing,
                status: "Optimizing modified sort",
                discovered: discoveredCount,
                searchable: lock.withLock { searchSnapshot.resultCount },
                optimized: 0,
                isIndexing: true,
                generation: currentGeneration
            )
        }

        guard isCurrentGeneration(currentGeneration) else { return }
        MemoryTelemetry.log(
            "optimize.modifiedSort.begin",
            records: Self.countOnlyMetrics(for: snapshot.store),
            structures: snapshot.diagnostics,
            store: snapshot.store,
            activeIndexJobs: currentActiveIndexJobCount(),
            context: memoryTelemetryContext
        )
        snapshot = snapshot.addingModifiedSortOrder()
        MemoryTelemetry.log(
            "optimize.modifiedSort.end",
            records: Self.countOnlyMetrics(for: snapshot.store),
            structures: snapshot.diagnostics,
            store: snapshot.store,
            activeIndexJobs: currentActiveIndexJobCount(),
            context: memoryTelemetryContext
        )
        if publishesIntermediateSnapshots {
            publishOptimizedSnapshot(
                snapshot,
                status: "Saving index",
                optimized: snapshot.resultCount,
                generation: currentGeneration
            )
        } else {
            publishRebuildStatus(
                phase: .optimizing,
                status: "Saving index",
                discovered: discoveredCount,
                searchable: lock.withLock { searchSnapshot.resultCount },
                optimized: snapshot.resultCount,
                isIndexing: true,
                generation: currentGeneration
            )
        }

        guard isCurrentGeneration(currentGeneration) else { return }
        publishRebuildStatus(
            phase: .saving,
            status: "Saving index",
            discovered: discoveredCount,
            searchable: publishesIntermediateSnapshots ? snapshot.resultCount : lock.withLock { searchSnapshot.resultCount },
            optimized: snapshot.resultCount,
            isIndexing: true,
            generation: currentGeneration
        )
        do {
            MemoryTelemetry.log(
                "optimize.persistSearchStructures.begin",
                records: Self.countOnlyMetrics(for: snapshot.store),
                structures: snapshot.diagnostics,
                store: snapshot.store,
                activeIndexJobs: currentActiveIndexJobCount(),
                context: memoryTelemetryContext
            )
            try persistSearchStructures(for: snapshot, packageURL: pendingMappedPackageURL)
            MemoryTelemetry.log(
                "optimize.persistSearchStructures.end",
                records: Self.countOnlyMetrics(for: snapshot.store),
                structures: snapshot.diagnostics,
                store: snapshot.store,
                activeIndexJobs: currentActiveIndexJobCount(),
                context: memoryTelemetryContext
            )
        } catch {
            failIndexing("Could not save optimized search index: \(error.localizedDescription)", generation: currentGeneration)
            return
        }

        MemoryTelemetry.log(
            "optimize.installMappedSnapshot.begin",
            records: Self.countOnlyMetrics(for: snapshot.store),
            structures: snapshot.diagnostics,
            store: snapshot.store,
            activeIndexJobs: currentActiveIndexJobCount(),
            context: memoryTelemetryContext
        )
        guard installMappedSnapshotPackage(pendingMappedPackageURL, generation: currentGeneration) else { return }
        MemoryTelemetry.log(
            "optimize.installMappedSnapshot.end",
            records: Self.countOnlyMetrics(for: snapshot.store),
            structures: snapshot.diagnostics,
            store: snapshot.store,
            activeIndexJobs: currentActiveIndexJobCount(),
            context: memoryTelemetryContext
        )

        let shouldReconcileAfterFinish = lock.withLock {
            resumedFromCheckpoint && completionStatusPrefix == "Indexed"
        }
        let didFinish = lock.withLock { () -> Bool in
            guard generation == currentGeneration else {
                return false
            }

            self.recordsByPath.removeAll(keepingCapacity: false)
            searchSnapshot = snapshot
            searchSnapshotRevision &+= 1
            indexing = false
            if reconciling {
                clearActiveReconciliationWithoutLock()
            }
            reconciling = false
            updating = false
            phase = .ready
            self.discoveredCount = snapshot.resultCount
            searchableCount = snapshot.resultCount
            optimizedCount = snapshot.resultCount
            status = Self.completionStatus(
                prefix: completionStatusPrefix,
                recordCount: snapshot.resultCount,
                startedAt: operationStartedAt
            )
            lastUpdated = Date()
            activeOperationStartedAt = nil
            resumedFromCheckpoint = false
            completedSnapshotRebuilds &+= 1
            return true
        }

        if didFinish {
            publishStats()
            let revision = lock.withLock { searchSnapshotRevision }
            startPathGramBuildIfNeeded(
                snapshot: snapshot,
                packageURL: snapshotURL,
                generation: currentGeneration,
                baseSnapshotRevision: revision
            )
            MemoryTelemetry.log(
                "rebuild.optimized.applied",
                records: Self.countOnlyMetrics(for: snapshot.store),
                structures: snapshot.diagnostics,
                store: snapshot.store,
                activeIndexJobs: currentActiveIndexJobCount(),
                context: memoryTelemetryContext
            )
            if shouldReconcileAfterFinish {
                requestBackgroundReconciliation()
            }
        }
    }

    private func optimizeLoadedSnapshot(generation currentGeneration: UInt64) {
        let started = Date()
        let maintenanceMeasurement = MaintenanceMeasurement(startedAt: started)
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
            status: "Saving index",
            optimized: snapshot.resultCount,
            generation: currentGeneration
        )

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
            reconciling = false
            updating = false
            phase = .ready
            discoveredCount = snapshot.resultCount
            searchableCount = snapshot.resultCount
            optimizedCount = snapshot.resultCount
            status = "Loaded \(snapshot.resultCount) indexed files"
            lastUpdated = Date()
            activeOperationStartedAt = nil
            resumedFromCheckpoint = false
            return true
        }

        if didFinish {
            publishStats()
            clearDeferredOptimizationMarker()
            recordMaintenance(maintenanceMeasurement.operation(
                kind: .optimization,
                priority: .interactive,
                records: snapshot.resultCount
            ))
            let revision = lock.withLock { searchSnapshotRevision }
            startPathGramBuildIfNeeded(
                snapshot: snapshot,
                packageURL: snapshotURL,
                generation: currentGeneration,
                baseSnapshotRevision: revision
            )
            requestBackgroundReconciliation()
        }
    }

    private func startPathGramBuildIfNeeded(
        snapshot: SearchSnapshot,
        packageURL: URL,
        generation currentGeneration: UInt64,
        baseSnapshotRevision: UInt64
    ) {
        guard snapshot.gramIndex == nil,
              snapshot.count <= Self.pathGramRecordLimit,
              snapshot.store.mappedByteSize <= Self.pathGramTotalPathByteLimit else {
            return
        }

        let didMarkActive = lock.withLock { () -> Bool in
            guard
                generation == currentGeneration,
                searchSnapshotRevision == baseSnapshotRevision,
                searchSnapshot.store === snapshot.store,
                activePathGramBuildGeneration == nil
            else {
                return false
            }
            activePathGramBuildGeneration = currentGeneration
            return true
        }
        guard didMarkActive else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let jobID = self.beginIndexJob("pathGramBuild")
            defer {
                self.lock.withLock {
                    if self.activePathGramBuildGeneration == currentGeneration {
                        self.activePathGramBuildGeneration = nil
                    }
                }
                self.endIndexJob("pathGramBuild", jobID: jobID)
            }

            guard FileIndex.shouldBuildPathGramIndex(store: snapshot.store) else {
                return
            }

            var builderBaseRevision = baseSnapshotRevision
            let publishedExpectedRowCount = self.lock.withLock { () -> Bool in
                guard
                    self.generation == currentGeneration,
                    self.searchSnapshot.store === snapshot.store,
                    self.searchSnapshot.gramIndex == nil
                else {
                    return false
                }
                guard self.searchSnapshot.pathGramExpectedRowCount != snapshot.count else {
                    builderBaseRevision = self.searchSnapshotRevision
                    return false
                }
                self.searchSnapshot = self.searchSnapshot.settingPathGramExpectedRowCount(snapshot.count)
                self.searchSnapshotRevision &+= 1
                builderBaseRevision = self.searchSnapshotRevision
                self.lastUpdated = Date()
                return true
            }
            let canBuild = self.lock.withLock {
                self.generation == currentGeneration
                    && self.searchSnapshot.store === snapshot.store
                    && self.searchSnapshot.gramIndex == nil
            }
            guard canBuild else { return }
            if publishedExpectedRowCount {
                self.publishStats()
            }

            self.buildPathGramSidecar(
                for: snapshot,
                packageURL: packageURL,
                generation: currentGeneration,
                baseSnapshotRevision: builderBaseRevision
            )
        }
    }

    private func buildPathGramSidecar(
        for snapshot: SearchSnapshot,
        packageURL: URL,
        generation currentGeneration: UInt64,
        baseSnapshotRevision _: UInt64
    ) {
        let started = Date()
        let maintenanceMeasurement = MaintenanceMeasurement(startedAt: started)
        let rowCount = snapshot.count
        var fullPostingMap: [Int: [Int32]] = [:]
        var completedRangeCount = 0

        for lowerBound in stride(from: 0, to: rowCount, by: Self.pathGramShardSize) {
            let isCurrentStore = lock.withLock {
                generation == currentGeneration
                    && searchSnapshot.store === snapshot.store
                    && searchSnapshot.gramIndex == nil
            }
            guard isCurrentStore else {
                return
            }

            let upperBound = min(rowCount, lowerBound + Self.pathGramShardSize)
            let range = lowerBound..<upperBound
            SearchSnapshot.appendPathGramPostings(
                store: snapshot.store,
                range: range,
                to: &fullPostingMap
            )
            completedRangeCount += 1
        }

        let isCurrentStore = lock.withLock {
            generation == currentGeneration
                && searchSnapshot.store === snapshot.store
                && searchSnapshot.gramIndex == nil
        }
        guard isCurrentStore else {
            return
        }

        let stagedURL = supportDirectory.appendingPathComponent(
            "path-postings-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: stagedURL) }

        let completeIndex: MappedIntPostingIndex
        do {
            guard let builtIndex = try MappedIntPostingIndex.build(
                from: fullPostingMap,
                outputURL: stagedURL
            ) else {
                return
            }
            completeIndex = builtIndex
        } catch {
            recordPersistFailure()
            DiagnosticLogger.shared.log(
                level: .error,
                category: "index",
                event: "index.pathGramBuildFailed",
                fields: [
                    "recordCount": .publicInt(rowCount),
                    "error": .errorText(error.localizedDescription)
                ]
            )
            return
        }

        var persistError: Error?
        let didComplete = lock.withLock { () -> Bool in
            guard
                generation == currentGeneration,
                searchSnapshot.store === snapshot.store,
                searchSnapshot.gramIndex == nil
            else {
                return false
            }

            do {
                let destinationURL = packageURL.appendingPathComponent(
                    SnapshotLayout.FileName.pathPostings,
                    isDirectory: false
                )
                if fileManager.fileExists(atPath: destinationURL.path) {
                    _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagedURL)
                } else {
                    try fileManager.moveItem(at: stagedURL, to: destinationURL)
                }
            } catch {
                persistError = error
                return false
            }

            searchSnapshot = searchSnapshot.addingCompletePathGramIndex(completeIndex)
            searchSnapshotRevision &+= 1
            lastUpdated = Date()
            return true
        }

        if let persistError {
            recordPersistFailure()
            DiagnosticLogger.shared.log(
                level: .error,
                category: "index",
                event: "index.pathGramSidecarPersistFailed",
                fields: [
                    "recordCount": .publicInt(rowCount),
                    "error": .errorText(persistError.localizedDescription)
                ]
            )
        }

        if didComplete {
            publishStats()
            MemoryTelemetry.log(
                "pathGrams.complete.applied",
                records: Self.countOnlyMetrics(for: snapshot.store),
                structures: lock.withLock { searchSnapshot.diagnostics },
                activeIndexJobs: currentActiveIndexJobCount()
            )
            DiagnosticLogger.shared.log(
                category: "index",
                event: "index.pathGramSidecarFinished",
                fields: [
                    "recordCount": .publicInt(rowCount),
                    "rangeCount": .publicInt(completedRangeCount),
                    "durationSeconds": .publicDouble(Date().timeIntervalSince(started))
                ]
            )
            recordMaintenance(maintenanceMeasurement.operation(
                kind: .pathGramBuild,
                priority: .background,
                records: rowCount
            ))
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
            updating = false
            phase = .optimizing
            discoveredCount = snapshot.resultCount
            searchableCount = snapshot.resultCount
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
            try installMappedSnapshotPackage(packageURL)
            return true
        } catch {
            failIndexing("Could not install compact index: \(error.localizedDescription)", generation: currentGeneration)
            return false
        }
    }

    private func installMappedSnapshotPackage(_ packageURL: URL) throws {
        try replaceMappedSnapshotPackageOnDisk(packageURL)
        lock.withLock {
            structuralDelta = nil
            clearStructuralDeltaCompactionWithoutLock()
            clearSnapshotDurabilityPendingWithoutLock()
        }
        finishMappedSnapshotInstallation()
    }

    private func replaceMappedSnapshotPackageOnDisk(_ packageURL: URL) throws {
        if fileManager.fileExists(atPath: snapshotURL.path) {
            try fileManager.removeItem(at: snapshotURL)
        }
        try fileManager.moveItem(at: packageURL, to: snapshotURL)
        removePersistedMetadataOverlay()
        try? structuralDeltaStore.clear()
    }

    private func finishMappedSnapshotInstallation() {
        removeScanCheckpoint()
        cleanupObsoleteIndexFiles()
        invalidateStorageInsightsCache()
    }

    private func failIndexing(_ message: String, generation currentGeneration: UInt64) {
        let didApply = lock.withLock { () -> Bool in
            guard generation == currentGeneration else {
                return false
            }

            indexing = false
            reconciling = false
            updating = false
            clearActiveReconciliationWithoutLock()
            phase = .failed
            status = message
            lastUpdated = Date()
            activeOperationStartedAt = nil
            resumedFromCheckpoint = false
            return true
        }

        if didApply {
            recordIndexingFailure()
            publishStats()
        }
    }

    private func publishRootLimitFailure(count: Int) {
        lock.withLock {
            generation &+= 1
            activePathGramBuildGeneration = nil
            clearOptimizedSearchFallbackWithoutLock()
            indexing = false
            reconciling = false
            updating = false
            activityPresentation = .foreground
            clearActiveReconciliationWithoutLock()
            phase = .failed
            status = "The index supports at most \(Self.maximumIndexedRootCount.formatted()) roots, but \(count.formatted()) were configured."
            discoveredCount = 0
            searchableCount = searchSnapshot.resultCount
            optimizedCount = searchSnapshot.isOptimizedForSearch ? searchSnapshot.resultCount : 0
            lastUpdated = Date()
            activeOperationStartedAt = nil
            resumedFromCheckpoint = false
        }
        wakeBackgroundReconciliation()
        recordIndexingFailure()
        publishStats()
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
            if !isIndexing {
                reconciling = false
                updating = false
            }
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

    private static func refreshScanWorkerCount() -> Int {
        if
            let rawValue = ProcessInfo.processInfo.environment["ATT_INDEX_REFRESH_SCAN_WORKERS"],
            let requested = Int(rawValue),
            requested > 0
        {
            return min(max(requested, 1), 64)
        }

        return min(2, max(1, ProcessInfo.processInfo.activeProcessorCount / 4))
    }

    private static func seconds(for interval: DispatchTimeInterval) -> TimeInterval {
        switch interval {
        case let .seconds(value):
            TimeInterval(value)
        case let .milliseconds(value):
            TimeInterval(value) / 1_000
        case let .microseconds(value):
            TimeInterval(value) / 1_000_000
        case let .nanoseconds(value):
            TimeInterval(value) / 1_000_000_000
        case .never:
            0
        @unknown default:
            0
        }
    }

    private static func operationElapsed(_ elapsed: TimeInterval) -> String {
        let totalSeconds = max(Int(elapsed.rounded()), 0)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return "\(hours)h \(String(format: "%02dm", minutes))"
        }
        if minutes > 0 {
            return "\(minutes)m \(String(format: "%02ds", seconds))"
        }
        return "\(seconds)s"
    }

    private static func completionStatus(prefix: String, recordCount: Int, startedAt: Date?) -> String {
        var status = "\(prefix) \(recordCount.formatted()) files"
        if let startedAt {
            status += " in \(operationElapsed(Date().timeIntervalSince(startedAt)))"
        }
        return status
    }

    private static func shouldPreserveReadyStatusDuringNoopUpdate(_ status: String) -> Bool {
        status.hasPrefix("Indexed ")
            || status.hasPrefix("Reconciled ")
            || status.hasPrefix("Caught up ")
            || status.hasPrefix("Loaded ")
    }

    private static func configuredLargeOverlayPersistRecordLimit() -> Int {
        guard
            let rawValue = ProcessInfo.processInfo.environment["ATT_INDEX_LARGE_OVERLAY_PERSIST_RECORD_LIMIT"],
            let requested = Int(rawValue),
            requested >= 0
        else {
            return exactEmptyQuerySortLimit
        }

        return requested
    }

    private static func configuredLargeOverlayPersistDelay() -> TimeInterval {
        guard
            let rawValue = ProcessInfo.processInfo.environment["ATT_INDEX_LARGE_OVERLAY_PERSIST_DELAY_SECONDS"],
            let requested = TimeInterval(rawValue),
            requested >= 0
        else {
            return largeOverlayPersistDefaultDelay
        }

        return requested
    }

    private static func configuredMetadataOverlayPersistDelay() -> TimeInterval {
        guard
            let rawValue = ProcessInfo.processInfo.environment["ATT_INDEX_METADATA_OVERLAY_PERSIST_DELAY_SECONDS"],
            let requested = TimeInterval(rawValue),
            requested >= 0
        else {
            return metadataOverlayPersistDefaultDelay
        }

        return requested
    }

    private static func configuredMetadataOverlayCheckpointDelay() -> TimeInterval {
        guard
            let rawValue = ProcessInfo.processInfo.environment["ATT_INDEX_METADATA_OVERLAY_CHECKPOINT_DELAY_SECONDS"],
            let requested = TimeInterval(rawValue),
            requested >= 0
        else {
            return metadataOverlayCheckpointDefaultDelay
        }

        return requested
    }

    private func largeOverlayPersistRecordLimit() -> Int {
        largeOverlayPersistRecordLimitOverride ?? Self.configuredLargeOverlayPersistRecordLimit()
    }

    private func largeOverlayPersistDelay(immediateLargeOverlay: Bool = false) -> TimeInterval {
        if let largeOverlayPersistDelayOverride {
            return largeOverlayPersistDelayOverride
        }
        return immediateLargeOverlay ? 0 : Self.configuredLargeOverlayPersistDelay()
    }

    private func largeOverlayChangedPathThreshold() -> Int {
        largeOverlayChangedPathThresholdOverride ?? Self.largeOverlayChangedPathDefaultThreshold
    }

    private func largeOverlayDrainBackoffDelay() -> TimeInterval {
        largeOverlayDrainBackoffDelayOverride ?? Self.largeOverlayDrainBackoffDefaultDelay
    }

    private func backgroundRefreshBatchLimit() -> Int {
        backgroundRefreshBatchLimitOverride ?? Self.backgroundRefreshBatchDefaultLimit
    }

    private func backgroundRefreshDrainBackoffDelay() -> TimeInterval {
        backgroundRefreshDrainBackoffDelayOverride ?? Self.backgroundRefreshDrainBackoffDefaultDelay
    }

    private static func backgroundRefreshRetryDelay(
        baseDelay: TimeInterval,
        priorFailureCount: Int
    ) -> TimeInterval {
        let boundedBaseDelay = max(baseDelay, 0)
        let exponent = min(max(priorFailureCount, 0), 20)
        return min(
            boundedBaseDelay * pow(2, Double(exponent)),
            backgroundRefreshRetryMaximumDelay
        )
    }

    private func backgroundDirectoryScanBudget() -> TimeInterval {
        backgroundDirectoryScanBudgetOverride ?? Self.backgroundDirectoryScanBudgetDefault
    }

    private func pauseBackgroundReconciliationIfNeeded(
        enabled: Bool,
        generation currentGeneration: UInt64,
        workerCount: Int,
        sliceStartedAt: inout Date,
        isStoppedOrComplete: @Sendable () -> Bool,
        onYield: @Sendable (TimeInterval) -> Void
    ) -> Bool {
        guard !isStoppedOrComplete() else { return false }
        guard enabled else { return isCurrentGeneration(currentGeneration) }

        let initialState = lock.withLock {
            (
                isCurrent: generation == currentGeneration,
                backgroundEnteredAt: backgroundMaintenanceEnteredAt,
                isPromoted: promotedReconciliationGeneration == currentGeneration
            )
        }
        guard initialState.isCurrent else { return false }
        guard !initialState.isPromoted else { return true }
        guard initialState.backgroundEnteredAt != nil else { return true }

        backgroundReconciliationCondition.lock()
        defer { backgroundReconciliationCondition.unlock() }

        while true {
            guard !isStoppedOrComplete() else { return false }
            let state = lock.withLock {
                (
                    isCurrent: generation == currentGeneration,
                    backgroundEnteredAt: backgroundMaintenanceEnteredAt,
                    isPromoted: promotedReconciliationGeneration == currentGeneration
                )
            }
            guard state.isCurrent else { return false }
            guard !state.isPromoted else { return true }
            guard let backgroundEnteredAt = state.backgroundEnteredAt else { return true }

            let now = Date()
            let effectiveSliceStart = max(sliceStartedAt, backgroundEnteredAt)
            let perWorkerBudget = backgroundDirectoryScanBudget() / Double(max(workerCount, 1))
            guard now.timeIntervalSince(effectiveSliceStart) >= perWorkerBudget else {
                return true
            }

            let delay = backgroundRefreshDrainBackoffDelay()
            onYield(delay)
            guard delay > 0 else {
                sliceStartedAt = Date()
                return true
            }

            let resumeDate = now.addingTimeInterval(delay)
            while Date() < resumeDate {
                if backgroundReconciliationCondition.wait(until: resumeDate) {
                    break
                }
            }
            guard !isStoppedOrComplete() else { return false }
            sliceStartedAt = Date()
        }
    }

    private func wakeBackgroundReconciliation() {
        backgroundReconciliationCondition.lock()
        backgroundReconciliationCondition.broadcast()
        backgroundReconciliationCondition.unlock()
    }

    private func backgroundDirectoryScanVisitLimit(for priority: IndexWorkPriority) -> Int? {
        guard priority == .background else { return nil }
        return backgroundDirectoryScanVisitLimitOverride
            ?? Self.backgroundDirectoryScanVisitDefaultLimit
    }

    private func backgroundDirectoryScanEntryLimit(for priority: IndexWorkPriority) -> Int? {
        guard priority == .background else { return nil }
        return backgroundDirectoryScanEntryLimitOverride
            ?? Self.backgroundDirectoryScanEntryDefaultLimit
    }

    private func backgroundDirectoryFinalizationLimit(for priority: IndexWorkPriority) -> Int? {
        guard priority == .background else { return nil }
        return backgroundDirectoryFinalizationLimitOverride
            ?? Self.backgroundDirectoryFinalizationDefaultLimit
    }

    private func backgroundOptimizationPersistDelay() -> TimeInterval {
        backgroundOptimizationPersistDelayOverride ?? Self.backgroundOptimizationPersistDefaultDelay
    }

    private func metadataOverlayPersistDelay() -> TimeInterval {
        metadataOverlayPersistDelayOverride ?? Self.configuredMetadataOverlayPersistDelay()
    }

    private func metadataOverlayCheckpointDelay() -> TimeInterval {
        metadataOverlayCheckpointDelayOverride ?? Self.configuredMetadataOverlayCheckpointDelay()
    }

    private func metadataOverlayPersistLimit() -> Int {
        metadataOverlayPersistLimitOverride ?? Self.metadataOverlayPersistDefaultLimit
    }

    private func usageMetricsMaintenanceSaveDelay() -> TimeInterval {
        usageMetricsMaintenanceSaveDelayOverride ?? Self.usageMetricsMaintenanceSaveDefaultDelay
    }

    private func queuePendingRefreshPathsWithoutLock(
        _ paths: Set<String>,
        priority: IndexWorkPriority,
        recursivelyScansDirectory: Bool = true,
        queuedAt: Date,
        completion: PendingRefreshCompletion? = nil
    ) {
        for path in paths {
            queuePendingRefreshWorkWithoutLock(
                PendingRefreshWork(
                    path: path,
                    priority: priority,
                    recursivelyScansDirectory: recursivelyScansDirectory,
                    followUpRecursivelyScansDirectory: false,
                    firstQueuedAt: queuedAt,
                    completions: completion.map { [$0] } ?? [],
                    followUpCompletions: [],
                    directoryScanProgress: nil,
                    requiresDirectoryRescanAfterProgress: false,
                    eligibleAt: nil,
                    lastServiceSequence: nil,
                    retryAttempt: 0
                )
            )
        }
    }

    private func queuePendingRefreshWorksWithoutLock(_ works: [PendingRefreshWork]) {
        for work in works {
            queuePendingRefreshWorkWithoutLock(work)
        }
    }

    private func queuePendingRefreshWorkWithoutLock(_ work: PendingRefreshWork) {
        var queuedWork = work
        markOverlappingDirectoryProgressWithoutLock(for: &queuedWork)
        if var existing = pendingRefreshPaths[queuedWork.path] {
            if existing.directoryScanProgress == nil, queuedWork.directoryScanProgress != nil {
                queuedWork.merge(existing)
                pendingRefreshPaths[queuedWork.path] = queuedWork
            } else {
                existing.merge(queuedWork)
                pendingRefreshPaths[queuedWork.path] = existing
            }
        } else {
            pendingRefreshPaths[queuedWork.path] = queuedWork
        }
    }

    private func markOverlappingDirectoryProgressWithoutLock(for work: inout PendingRefreshWork) {
        var ancestorPath = Self.parentPath(of: work.path)
        while let path = ancestorPath {
            if let ancestor = pendingRefreshPaths[path],
               ancestor.directoryScanProgress?.supersedeSubtree(at: work.path) == true {
                Self.addCompletionDependencies(from: ancestor.completions, to: &work.completions)
            }
            ancestorPath = Self.parentPath(of: path)
        }

        guard work.directoryScanProgress != nil else { return }
        for descendantPath in Array(pendingRefreshPaths.keys)
        where Self.isStrictDescendant(descendantPath, of: work.path) {
            guard var descendant = pendingRefreshPaths[descendantPath] else { continue }
            if work.directoryScanProgress?.supersedeSubtree(at: descendant.path) == true {
                Self.addCompletionDependencies(from: work.completions, to: &descendant.completions)
                pendingRefreshPaths[descendantPath] = descendant
            }
        }
    }

    private static func addCompletionDependencies(
        from source: [PendingRefreshCompletion],
        to destination: inout [PendingRefreshCompletion]
    ) {
        var destinationIDs = Set(destination.map(ObjectIdentifier.init))
        for completion in source {
            let identifier = ObjectIdentifier(completion)
            guard !destinationIDs.contains(identifier), completion.addPathDependency() else { continue }
            destination.append(completion)
            destinationIDs.insert(identifier)
        }
    }

    private static func isStrictDescendant(_ path: String, of ancestor: String) -> Bool {
        path != ancestor && (ancestor == "/" || path.hasPrefix(ancestor + "/"))
    }

    private static func parentPath(of path: String) -> String? {
        guard path != "/", let separator = path.lastIndex(of: "/") else { return nil }
        return separator == path.startIndex ? "/" : String(path[..<separator])
    }

    private static func refreshBatchPriority(_ works: [PendingRefreshWork]) -> IndexWorkPriority {
        works.contains { $0.priority == .interactive } ? .interactive : .background
    }

    private static func hasInteractiveRefreshWork<Works: Sequence>(_ works: Works) -> Bool
    where Works.Element == PendingRefreshWork {
        works.contains { $0.priority == .interactive }
    }

    private static func requiresBackgroundDirectoryDelay(_ work: PendingRefreshWork) -> Bool {
        guard work.priority == .background, work.recursivelyScansDirectory else { return false }
        return work.directoryScanProgress?.finalization?.phase != .readyToCommit
    }

    private static func nonoverlappingRefreshBatch(
        from works: [PendingRefreshWork],
        maximumCount: Int,
        eligibleAt date: Date
    ) -> [PendingRefreshWork] {
        guard maximumCount > 0, !works.isEmpty else { return [] }

        let allWorks = works.sorted { $0.path < $1.path }
        var promotedAncestorPaths = Set<String>()
        var unblockedWorks: [PendingRefreshWork] = []
        unblockedWorks.reserveCapacity(min(allWorks.count, maximumCount))
        var ancestorStack: [PendingRefreshWork] = []

        for work in allWorks {
            while let candidate = ancestorStack.last,
                  !Self.isStrictDescendant(work.path, of: candidate.path) {
                ancestorStack.removeLast()
            }

            let blockingAncestor = ancestorStack.first { ancestor in
                ancestor.isEligible(at: date)
                    && ancestor.recursivelyScansDirectory
                    && ancestor.directoryScanProgress?.isSuperseded(work.path) != true
            }
            if let blockingAncestor {
                if work.priority == .interactive {
                    promotedAncestorPaths.insert(blockingAncestor.path)
                }
            } else {
                unblockedWorks.append(work)
            }
            ancestorStack.append(work)
        }

        for index in unblockedWorks.indices where promotedAncestorPaths.contains(unblockedWorks[index].path) {
            unblockedWorks[index].promote()
        }
        unblockedWorks.removeAll { !$0.isEligible(at: date) }
        unblockedWorks.sort { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority == .interactive
            }
            if lhs.lastServiceSequence != rhs.lastServiceSequence {
                guard let lhsSequence = lhs.lastServiceSequence else { return true }
                guard let rhsSequence = rhs.lastServiceSequence else { return false }
                return lhsSequence < rhsSequence
            }
            if lhs.firstQueuedAt != rhs.firstQueuedAt {
                return lhs.firstQueuedAt < rhs.firstQueuedAt
            }
            return lhs.path < rhs.path
        }
        return Array(unblockedWorks.prefix(maximumCount))
    }

    private func scheduleUpdateDrainIfNeeded(delay: DispatchTimeInterval) {
        let requestedDelay = max(Self.seconds(for: delay), 0)
        let scheduled = lock.withLock { () -> (
            shouldSchedule: Bool,
            scheduleGeneration: UInt64,
            pendingPathCount: Int,
            maximumBatchPathCount: Int,
            deadline: Date
        ) in
            let now = Date()
            guard !pendingRefreshPaths.isEmpty else {
                return (false, refreshDrainScheduleGeneration, 0, Self.maximumRefreshBatchPaths, now)
            }

            let works = Array(pendingRefreshPaths.values)
            let eligibleWorks = Self.nonoverlappingRefreshBatch(
                from: works,
                maximumCount: works.count,
                eligibleAt: now
            )
            let priority = Self.hasInteractiveRefreshWork(eligibleWorks)
                ? IndexWorkPriority.interactive
                : .background
            var deadline = now.addingTimeInterval(requestedDelay)
            if eligibleWorks.isEmpty,
               let earliestEligibility = works.compactMap(\.eligibleAt).min(),
               earliestEligibility > deadline {
                deadline = earliestEligibility
            }
            if isRefreshDrainScheduled {
                let promotesPriority = scheduledRefreshDrainPriority == .background && priority == .interactive
                let movesEarlier = scheduledRefreshDrainDeadline.map { deadline < $0 } ?? true
                guard promotesPriority || movesEarlier else {
                    return (
                        false,
                        refreshDrainScheduleGeneration,
                        pendingRefreshPaths.count,
                        priority == .interactive ? Self.maximumRefreshBatchPaths : backgroundRefreshBatchLimit(),
                        scheduledRefreshDrainDeadline ?? deadline
                    )
                }
            }

            refreshDrainScheduleGeneration &+= 1
            isRefreshDrainScheduled = true
            scheduledRefreshDrainPriority = priority
            scheduledRefreshDrainDeadline = deadline
            let maximumBatchPathCount = priority == .interactive
                ? Self.maximumRefreshBatchPaths
                : backgroundRefreshBatchLimit()
            return (
                true,
                refreshDrainScheduleGeneration,
                pendingRefreshPaths.count,
                maximumBatchPathCount,
                deadline
            )
        }

        guard scheduled.shouldSchedule else { return }

        if scheduled.pendingPathCount > scheduled.maximumBatchPathCount {
            DiagnosticLogger.shared.log(
                category: "index",
                event: "index.updateDrainScheduled",
                fields: [
                    "pendingPathCount": .publicInt(scheduled.pendingPathCount),
                    "maximumBatchPathCount": .publicInt(scheduled.maximumBatchPathCount),
                    "delaySeconds": .publicDouble(max(scheduled.deadline.timeIntervalSinceNow, 0))
                ]
            )
        }

        let effectiveDelay = max(scheduled.deadline.timeIntervalSinceNow, 0)
        indexQueue.asyncAfter(deadline: .now() + effectiveDelay) { [weak self] in
            self?.runScheduledUpdateDrain(generation: scheduled.scheduleGeneration)
        }
    }

    private func runScheduledUpdateDrain(generation scheduledGeneration: UInt64) {
        drainUpdateQueue(scheduledGeneration: scheduledGeneration)
    }

    private func drainUpdateQueue(scheduledGeneration: UInt64) {
        let drain = lock.withLock { () -> (
            acceptedSchedule: Bool,
            works: [PendingRefreshWork],
            priority: IndexWorkPriority,
            pendingPathCountAfterBatch: Int,
            deferredByIndexing: Bool,
            reconciling: Bool,
            updating: Bool,
            phase: IndexPhase
        ) in
            guard
                isRefreshDrainScheduled,
                refreshDrainScheduleGeneration == scheduledGeneration
            else {
                return (false, [], .interactive, pendingRefreshPaths.count, false, reconciling, updating, phase)
            }

            isRefreshDrainScheduled = false
            scheduledRefreshDrainPriority = nil
            scheduledRefreshDrainDeadline = nil
            guard !indexing else {
                return (true, [], .interactive, pendingRefreshPaths.count, true, reconciling, updating, phase)
            }

            let now = Date()
            let allWorks = Array(pendingRefreshPaths.values)
            let eligibleWorks = Self.nonoverlappingRefreshBatch(
                from: allWorks,
                maximumCount: allWorks.count,
                eligibleAt: now
            )
            let batchLimit = Self.hasInteractiveRefreshWork(eligibleWorks)
                ? Self.maximumRefreshBatchPaths
                : backgroundRefreshBatchLimit()
            let batch = Array(eligibleWorks.prefix(batchLimit))
            for work in batch {
                pendingRefreshPaths.removeValue(forKey: work.path)
            }
            let pendingPathCountAfterBatch = pendingRefreshPaths.count
            if pendingRefreshPaths.isEmpty {
                pendingRefreshPaths.removeAll(keepingCapacity: false)
            }
            return (
                true,
                batch,
                Self.refreshBatchPriority(batch),
                pendingPathCountAfterBatch,
                false,
                reconciling,
                updating,
                phase
            )
        }

        guard drain.acceptedSchedule else { return }

        if drain.deferredByIndexing {
            DiagnosticLogger.shared.log(
                category: "index",
                event: "index.updateDrainDeferred",
                fields: [
                    "reason": .publicString("indexing"),
                    "pendingPathCount": .publicInt(drain.pendingPathCountAfterBatch),
                    "reconciling": .publicBool(drain.reconciling),
                    "updating": .publicBool(drain.updating),
                    "phase": .publicString(drain.phase.rawValue)
                ]
            )
            return
        }

        var updateResult = RefreshUpdateResult.none
        if !drain.works.isEmpty {
            if drain.pendingPathCountAfterBatch > 0 {
                DiagnosticLogger.shared.log(
                    category: "index",
                    event: "index.updateDrainContinuing",
                    fields: [
                        "batchPathCount": .publicInt(drain.works.count),
                        "remainingPathCount": .publicInt(drain.pendingPathCountAfterBatch),
                        "maximumBatchPathCount": .publicInt(
                            drain.priority == .background ? backgroundRefreshBatchLimit() : Self.maximumRefreshBatchPaths
                        ),
                        "priority": .publicString(drain.priority.rawValue)
                    ]
                )
            }
            updateResult = updateNow(requests: drain.works)
        }

        // Exact-path bursts are cheap, finite work and should drain continuously.
        // Only recursive directory traversal needs the background duty-cycle cap.
        let backgroundResumeDate = updateResult.deferredRefreshes.contains(
            where: Self.requiresBackgroundDirectoryDelay
        )
            ? Date().addingTimeInterval(backgroundRefreshDrainBackoffDelay())
            : nil
        if !updateResult.deferredRefreshes.isEmpty {
            var deferredRefreshes = updateResult.deferredRefreshes
            if let backgroundResumeDate {
                for index in deferredRefreshes.indices
                where Self.requiresBackgroundDirectoryDelay(deferredRefreshes[index]) {
                    deferredRefreshes[index].deferBackgroundWork(until: backgroundResumeDate)
                }
            }
            lock.withLock {
                queuePendingRefreshWorksWithoutLock(deferredRefreshes)
            }
            DiagnosticLogger.shared.log(
                category: "index",
                event: "index.backgroundMaintenanceDeferred",
                fields: [
                    "deferredPathCount": .publicInt(updateResult.deferredRefreshes.count),
                    "visitedCount": .publicInt(updateResult.deferredDirectoryVisitCount),
                    "priority": .publicString(updateResult.priority.rawValue)
                ],
                diagnosticFields: [
                    "paths": .pathArray(updateResult.deferredRefreshes.map(\.path))
                ]
            )
        }

        let deferredPaths = Set(updateResult.deferredRefreshes.map(\.path))
        let explicitlyCompletedPaths = Set(updateResult.completedRefreshes.map(\.path))
        let finishedWorks = drain.works.filter {
            !deferredPaths.contains($0.path) && !explicitlyCompletedPaths.contains($0.path)
        }
        let completionWorks = finishedWorks + updateResult.completedRefreshes
        var completedWorks: [PendingRefreshWork] = []
        if updateResult.applied, updateResult.completionReady {
            completedWorks = completionWorks
        } else if updateResult.applied {
            lock.withLock {
                for work in completionWorks {
                    pendingDurabilityCompletions.append(contentsOf: work.completions)
                }
            }
            scheduleDurabilityRetry()
            schedulePersist(
                delay: backgroundOptimizationPersistDelay(),
                priority: .background
            )
        }

        Self.completePendingRefreshWorks(completedWorks)

        let remainingPathCount = lock.withLock { pendingRefreshPaths.count }
        if remainingPathCount > 0 {
            let delay: DispatchTimeInterval
            if let backgroundResumeDate {
                let backoff = max(backgroundResumeDate.timeIntervalSinceNow, 0)
                recordMaintenance(IndexMaintenanceOperationMetric(
                    kind: .backgroundSlice,
                    priority: .background,
                    yieldedSlices: 1,
                    deferredPaths: UInt64(max(updateResult.deferredRefreshes.count, 0))
                ))
                DiagnosticLogger.shared.log(
                    category: "index",
                    event: "index.backgroundMaintenanceSlice",
                    fields: [
                        "batchPathCount": .publicInt(updateResult.batchPathCount),
                        "remainingPathCount": .publicInt(remainingPathCount),
                        "changedPathCount": .publicInt(updateResult.changedPathCount),
                        "deferredPathCount": .publicInt(updateResult.deferredRefreshes.count),
                        "delaySeconds": .publicDouble(backoff)
                    ]
                )
                // The yielded directory carries its own eligibility date. Ask the
                // scheduler to run any independent exact work immediately; when
                // only yielded scopes remain it will select their earliest date.
                delay = .milliseconds(0)
            } else if updateResult.largeOverlay {
                let backoff = largeOverlayDrainBackoffDelay()
                DiagnosticLogger.shared.log(
                    category: "index",
                    event: "index.updateDrainBackoff",
                    fields: [
                        "batchPathCount": .publicInt(updateResult.batchPathCount),
                        "remainingPathCount": .publicInt(remainingPathCount),
                        "changedPathCount": .publicInt(updateResult.changedPathCount),
                        "delaySeconds": .publicDouble(backoff)
                    ]
                )
                delay = .milliseconds(Int((backoff * 1_000).rounded(.up)))
            } else {
                delay = .milliseconds(0)
            }
            scheduleUpdateDrainIfNeeded(delay: delay)
        } else {
            let shouldOptimize = lock.withLock { () -> Bool in
                guard optimizesSnapshotAfterPromotedRefreshDrain else { return false }
                optimizesSnapshotAfterPromotedRefreshDrain = false
                return !indexing
                    && searchSnapshot.store.kind == .overlay
                    && !searchSnapshot.isOptimizedForSearch
                    && !hasDurableStructuralDeltaBelowCompactionThresholdWithoutLock()
            }
            if shouldOptimize {
                schedulePersist(delay: 0)
            }
        }
    }

    private static func completePendingRefreshWorks(_ works: [PendingRefreshWork]) {
        for work in works {
            for completion in work.completions {
                completion.completeOnePath()
            }
        }
    }

    private func completePendingDurabilityCompletions() {
        let completions = lock.withLock { () -> [PendingRefreshCompletion] in
            let completions = pendingDurabilityCompletions
            pendingDurabilityCompletions.removeAll(keepingCapacity: false)
            clearSnapshotDurabilityPendingWithoutLock()
            return completions
        }
        for completion in completions {
            completion.completeOnePath()
        }
    }

    private func clearSnapshotDurabilityPendingWithoutLock() {
        hasUnpersistedSnapshotChanges = false
        unpersistedSnapshotRevision = nil
        durabilityRetryAttempt = 0
        durabilityRetryScheduled = false
        durabilityRetryGeneration &+= 1
    }

    private func advanceSearchSnapshotRevisionPreservingDurabilityWithoutLock() {
        searchSnapshotRevision &+= 1
        if hasUnpersistedSnapshotChanges {
            unpersistedSnapshotRevision = searchSnapshotRevision
        }
    }

    private func markSnapshotDurabilityPending(schedulesRetry: Bool = true) {
        lock.withLock {
            hasUnpersistedSnapshotChanges = true
            unpersistedSnapshotRevision = searchSnapshotRevision
        }
        if schedulesRetry {
            scheduleDurabilityRetry()
        }
    }

    private func markReadySnapshotDurabilityPendingIfNeeded() {
        let didMark = lock.withLock { () -> Bool in
            guard phase == .ready,
                  !indexing,
                  !reconciling,
                  !updating,
                  searchSnapshot.resultCount > 0,
                  !searchSnapshot.isOptimizedForSearch else {
                return false
            }
            hasUnpersistedSnapshotChanges = true
            unpersistedSnapshotRevision = searchSnapshotRevision
            return true
        }
        if didMark {
            scheduleDurabilityRetry()
        }
    }

    private func scheduleDurabilityRetry() {
        let retry = lock.withLock { () -> (generation: UInt64, attempt: Int, delay: TimeInterval)? in
            guard
                (hasUnpersistedSnapshotChanges || !pendingDurabilityCompletions.isEmpty),
                unpersistedSnapshotRevision == searchSnapshotRevision,
                !durabilityRetryScheduled
            else {
                return nil
            }

            let delays: [TimeInterval] = [5, 15, 60, 300]
            let attempt = durabilityRetryAttempt
            let delay = delays[min(attempt, delays.count - 1)]
            durabilityRetryAttempt = min(attempt + 1, delays.count - 1)
            durabilityRetryScheduled = true
            durabilityRetryGeneration &+= 1
            return (durabilityRetryGeneration, attempt + 1, delay)
        }
        guard let retry else { return }

        DiagnosticLogger.shared.log(
            category: "index",
            event: "index.durabilityRetryScheduled",
            fields: [
                "attempt": .publicInt(retry.attempt),
                "delaySeconds": .publicDouble(retry.delay)
            ]
        )

        indexQueue.asyncAfter(deadline: .now() + retry.delay) { [weak self] in
            guard let self else { return }
            let shouldRetry = self.lock.withLock { () -> Bool in
                guard
                    self.durabilityRetryScheduled,
                    self.durabilityRetryGeneration == retry.generation
                else {
                    return false
                }
                self.durabilityRetryScheduled = false
                return (self.hasUnpersistedSnapshotChanges || !self.pendingDurabilityCompletions.isEmpty)
                    && self.unpersistedSnapshotRevision == self.searchSnapshotRevision
                    && !self.indexing
                    && !self.reconciling
                    && !self.updating
                    && self.activeIndexJobs == 0
                    && self.activeDeferredOptimizationRevision == nil
                    && self.pendingRefreshPaths.isEmpty
                    && self.pendingReconciliationPaths.isEmpty
                    && !self.pendingReconciliationIncludesAllRoots
            }

            guard shouldRetry else {
                self.scheduleDurabilityRetry()
                return
            }
            if !self.persistSnapshot(priority: .background) {
                self.scheduleDurabilityRetry()
            }
        }
    }

    private func backgroundDirectoryScanDeadline(
        for priority: IndexWorkPriority,
        startedAt: Date
    ) -> Date? {
        let backgroundEnteredAt = lock.withLock { backgroundMaintenanceEnteredAt }
        guard priority == .background || backgroundEnteredAt != nil else { return nil }
        let budgetStartedAt = max(startedAt, backgroundEnteredAt ?? startedAt)
        return budgetStartedAt.addingTimeInterval(backgroundDirectoryScanBudget())
    }

    private func effectiveRefreshPriority(_ requestedPriority: IndexWorkPriority) -> IndexWorkPriority {
        lock.withLock {
            backgroundMaintenanceEnteredAt == nil ? requestedPriority : .background
        }
    }

    private func updateNow(requests: [PendingRefreshWork]) -> RefreshUpdateResult {
        let paths = requests.map(\.path)
        let updatePriority = effectiveRefreshPriority(Self.refreshBatchPriority(requests))
        let updateStarted = Date()
        let updateContext = lock.withLock { () -> (generation: UInt64, preservedReadyStatus: String?)? in
            guard !indexing else { return nil }
            let preservedReadyStatus = phase == .ready && Self.shouldPreserveReadyStatusDuringNoopUpdate(status)
                ? status
                : nil
            generation &+= 1
            activePathGramBuildGeneration = nil
            indexing = true
            reconciling = false
            updating = true
            activityPresentation = updatePriority == .background ? .backgroundCatchUp : .foreground
            clearActiveReconciliationWithoutLock()
            phase = .scanning
            status = updatePriority == .background ? "Catching up changed paths" : "Updating changed paths"
            activeOperationStartedAt = updateStarted
            resumedFromCheckpoint = false
            lastUpdated = Date()
            return (generation, preservedReadyStatus)
        }
        guard let updateContext else {
            lock.withLock {
                queuePendingRefreshWorksWithoutLock(requests)
            }
            scheduleUpdateDrainIfNeeded(delay: .milliseconds(0))
            return .none
        }
        let currentGeneration = updateContext.generation
        let maintenanceMeasurement = MaintenanceMeasurement(startedAt: updateStarted)
        recordScanFrontierMetrics(ScanFrontierMetrics(), generation: currentGeneration)
        publishStats()

        let jobID = beginIndexJob("update")
        defer { endIndexJob("update", jobID: jobID) }

        MemoryTelemetry.log(
            "update.begin",
            refreshBatchSize: paths.count,
            activeIndexJobs: currentActiveIndexJobCount()
        )
        DiagnosticLogger.shared.log(
            category: "index",
            event: "index.updateBegin",
            fields: [
                "pathCount": .publicInt(paths.count),
                "priority": .publicString(updatePriority.rawValue)
            ],
            diagnosticFields: [
                "paths": .pathArray(paths)
            ]
        )

        let indexState = lock.withLock {
            (
                exclusions: exclusionRules,
                rootPaths: roots,
                evaluationMode: exclusionEvaluationMode,
                frontierMode: scanFrontierMode
            )
        }
        let exclusionQuery = makeExclusionQuery(
            exclusions: indexState.exclusions,
            rootPaths: indexState.rootPaths,
            evaluationMode: indexState.evaluationMode
        )
        let previousSnapshot = lock.withLock { searchSnapshot }
        var upserts: [String: FileRecord] = [:]
        var deletedRows = Set<Int>()
        var deletedPrefixes: [String] = []
        var reconciledDirectoryPrefixes: [String] = []
        var deferredRefreshes: [PendingRefreshWork] = []
        var completedRefreshes: [PendingRefreshWork] = []
        var deferredDirectoryVisitCount = 0
        var visitedCount = 0
        var requestedDirectoryRefresh = false
        var exclusionInstrumentation = FileExclusionQuery.Instrumentation()
        var requiresDirectoryReconciliation = false
        let updateVolumeNameCache = ScanVolumeNameCache()

        func needsUpsert(_ record: FileRecord) -> Bool {
            if let rowID = previousSnapshot.store.rowID(forPath: record.path),
               Self.storedRecord(previousSnapshot.store, at: rowID, matches: record) {
                return false
            }
            return true
        }

        func stageUpsertIfChanged(_ record: FileRecord) {
            guard needsUpsert(record) else { return }
            upserts[record.path] = record
        }

        func coverFollowUpWithCurrentObservation(_ request: inout PendingRefreshWork) {
            guard request.requiresDirectoryRescanAfterProgress else { return }
            request.completions.append(contentsOf: request.followUpCompletions)
            request.followUpCompletions.removeAll(keepingCapacity: false)
            request.requiresDirectoryRescanAfterProgress = false
            request.followUpRecursivelyScansDirectory = false
            request.directoryScanProgress = nil
            completedRefreshes.append(request)
        }

        func stageDeletedRows(
            inSubtreeAt path: String,
            keeping shouldKeep: (String) -> Bool
        ) {
            if let subtreeRows = previousSnapshot.store.rowIDs(inSubtreeAtPath: path) {
                for existingRow in subtreeRows {
                    let existingPath = previousSnapshot.store.path(at: existingRow)
                    if !shouldKeep(existingPath) {
                        deletedRows.insert(existingRow)
                    }
                }
                return
            }

            // A mapped tree has complete path lookup and materializes virtual
            // ancestors, so a missing root proves there is no old subtree. Avoid
            // walking the entire snapshot for a newly introduced directory.
            if previousSnapshot.store.hasColumnarSidecars,
               previousSnapshot.store.rowID(forPath: path) == nil {
                return
            }

            for existingRow in 0..<previousSnapshot.count {
                let existingPath = previousSnapshot.store.path(at: existingRow)
                if (existingPath == path || existingPath.hasPrefix(path + "/")),
                   !shouldKeep(existingPath) {
                    deletedRows.insert(existingRow)
                }
            }
        }

        func makeUpdateResult(
            applied: Bool,
            largeOverlay: Bool,
            changedPathCount: Int,
            completionReady: Bool? = nil
        ) -> RefreshUpdateResult {
            let resultPriority = effectiveRefreshPriority(updatePriority)
            if applied {
                let operationKind: IndexMaintenanceOperationKind = (requestedDirectoryRefresh || visitedCount > 0 || requiresDirectoryReconciliation)
                    ? .directoryRefresh
                    : .exactRefresh
                recordMaintenance(
                    maintenanceMeasurement.operation(
                        kind: operationKind,
                        priority: resultPriority.maintenancePriority,
                        paths: paths.count,
                        records: changedPathCount,
                        visited: visitedCount,
                        yieldedSlices: deferredRefreshes.isEmpty ? 0 : 1,
                        deferredPaths: deferredRefreshes.count,
                        largeOverlays: largeOverlay ? 1 : 0,
                        exclusionInstrumentation: exclusionInstrumentation
                    )
                )
            }

            return RefreshUpdateResult(
                applied: applied,
                completionReady: completionReady ?? applied,
                largeOverlay: largeOverlay,
                priority: resultPriority,
                requestedDirectoryRefresh: requestedDirectoryRefresh,
                batchPathCount: paths.count,
                changedPathCount: changedPathCount,
                visitedCount: visitedCount,
                exclusionInstrumentation: exclusionInstrumentation,
                reconciledDirectoryPrefixes: reconciledDirectoryPrefixes,
                deferredRefreshes: deferredRefreshes,
                completedRefreshes: completedRefreshes,
                deferredDirectoryVisitCount: deferredDirectoryVisitCount
            )
        }

        func requeueRequestsAfterGenerationChange() {
            lock.withLock {
                let carriedPaths = Set(
                    deferredRefreshes.map(\.path) + completedRefreshes.map(\.path)
                )
                let untouchedRequests = requests.filter { !carriedPaths.contains($0.path) }
                queuePendingRefreshWorksWithoutLock(
                    completedRefreshes + deferredRefreshes + untouchedRequests
                )
            }
            scheduleUpdateDrainIfNeeded(delay: .milliseconds(0))
        }

        func stageCompletedDirectoryFinalization(
            _ progress: DirectoryUpdateScanProgress,
            at url: URL,
            request: inout PendingRefreshWork
        ) {
            guard let finalization = progress.finalization else { return }

            // The active work is temporarily absent from pendingRefreshPaths. Fold
            // in anything queued during this slice before committing, then mark
            // pending descendants as newer observations. Events arriving after
            // this barrier linearize after the directory pass and repair their row
            // in the next update.
            lock.withLock {
                if let queuedSamePath = pendingRefreshPaths.removeValue(forKey: request.path) {
                    request.merge(queuedSamePath)
                }
                markOverlappingDirectoryProgressWithoutLock(for: &request)
            }

            for path in finalization.preparedUpsertPaths
            where !progress.isSuperseded(path) && upserts[path] == nil {
                guard let record = finalization.unpublishedRecords[path] else { continue }
                stageUpsertIfChanged(record)
            }
            for path in finalization.deletionPaths
            where !progress.isSuperseded(path) && upserts[path] == nil {
                guard let rowID = previousSnapshot.store.rowID(forPath: path) else { continue }
                deletedRows.insert(rowID)
            }

            requiresDirectoryReconciliation = true
            reconciledDirectoryPrefixes.append(url.path)
            DiagnosticLogger.shared.log(
                category: "index",
                event: "index.directoryFinalizationCompleted",
                fields: [
                    "baselineRowsVisited": .publicInt(finalization.baselineRowsVisited),
                    "matchingBaselineRowsVisited": .publicInt(finalization.matchingBaselineRowsVisited),
                    "materializedDeletionPathCount": .publicInt(finalization.materializedDeletionPathCount),
                    "preparedDeletionCount": .publicInt(finalization.deletionPaths.count),
                    "preparedUpsertCount": .publicInt(finalization.preparedUpsertPaths.count),
                    "upsertsVisited": .publicInt(finalization.upsertsVisited)
                ],
                diagnosticFields: ["path": .path(url.path)]
            )

            var completedRequest = request
            completedRequest.followUpCompletions.removeAll(keepingCapacity: false)
            completedRequest.requiresDirectoryRescanAfterProgress = false
            completedRequest.directoryScanProgress = progress
            completedRefreshes.append(completedRequest)

            if request.requiresDirectoryRescanAfterProgress {
                request.prepareForFollowUpDirectoryScan()
                request.priority = effectiveRefreshPriority(request.priority)
                deferredRefreshes.append(request)
            }
        }

        for var request in requests {
            request.priority = effectiveRefreshPriority(request.priority)
            let path = request.path
            guard Self.path(path, isWithinAnyRoot: indexState.rootPaths) else {
                DiagnosticLogger.shared.log(
                    category: "index",
                    event: "index.updateDiscardedAfterRootChange",
                    diagnosticFields: ["path": .path(path)]
                )
                coverFollowUpWithCurrentObservation(&request)
                continue
            }
            if request.priority == .background,
               requestedDirectoryRefresh,
               let deadline = backgroundDirectoryScanDeadline(
                   for: request.priority,
                   startedAt: updateStarted
               ),
               Date() >= deadline {
                deferredRefreshes.append(request)
                continue
            }
            autoreleasepool {
                // Refresh paths are canonicalized once at queue ingress and retain
                // that representation across yielded slices.
                let url = URL(fileURLWithPath: path)
                switch fileSystemRecordLookup(for: url, volumeNameCache: updateVolumeNameCache) {
                case let .record(candidate):
                    let decision = exclusionDecision(
                        for: candidate.url,
                        exclusions: indexState.exclusions,
                        rootPaths: indexState.rootPaths,
                        query: exclusionQuery,
                        isDirectory: candidate.isDirectory,
                        instrumentation: &exclusionInstrumentation
                    )
                    guard decision != .prune else {
                        coverFollowUpWithCurrentObservation(&request)
                        return
                    }

                    if decision.shouldIndex {
                        stageUpsertIfChanged(candidate.record)
                    }

                    if request.recursivelyScansDirectory,
                       candidate.isDirectory,
                       !candidate.isSymlink,
                       decision.shouldDescend {
                        requestedDirectoryRefresh = true
                        var concurrentlyScannedRecords: [String: FileRecord]?
                        if indexState.frontierMode == .singleDirectory {
                            let progress = request.directoryScanProgress
                                ?? DirectoryUpdateScanProgress(
                                    root: candidate.url,
                                    baselineStore: previousSnapshot.store
                                )

                            if progress.finalization == nil {
                                let scanResult = scanDirectoryForUpdate(
                                    progress: progress,
                                    exclusions: indexState.exclusions,
                                    rootPaths: indexState.rootPaths,
                                    query: exclusionQuery,
                                    requestedPriority: request.priority,
                                    startedAt: updateStarted,
                                    maximumVisitCount: backgroundDirectoryScanVisitLimit(for: request.priority),
                                    maximumEntryCount: backgroundDirectoryScanEntryLimit(for: request.priority),
                                    generation: currentGeneration
                                )
                                guard let scanResult else {
                                    request.directoryScanProgress = progress
                                    request.priority = effectiveRefreshPriority(request.priority)
                                    deferredRefreshes.append(request)
                                    return
                                }

                                let scanWorkCount = scanResult.visitedCount + scanResult.readEntryCount
                                progress.traversalWorkCount += scanWorkCount
                                if scanResult.encounteredRetryError {
                                    request.deferAfterRetryFailure(
                                        baseDelay: backgroundRefreshDrainBackoffDelay()
                                    )
                                } else if scanWorkCount > 0 {
                                    request.clearRetryBackoffAfterProgress()
                                }
                                if scanWorkCount > 0 {
                                    request.markServiced(sequence: nextRefreshServiceSequence())
                                }
                                exclusionInstrumentation.add(scanResult.exclusionInstrumentation)
                                visitedCount += scanWorkCount
                                deferredDirectoryVisitCount += scanWorkCount
                                let completesCurrentTraversal = scanResult.completed
                                let canPublishIncrementally = progress.incrementalPublishBatchCount
                                    < Self.backgroundDirectoryIncrementalPublishBatchLimit
                                var publishedIncrementalChange = false
                                for record in scanResult.records.values
                                where !progress.isSuperseded(record.path) && needsUpsert(record) {
                                    if completesCurrentTraversal {
                                        // Final-slice changes join the resumable
                                        // commit so reconciliation is published as
                                        // one structural update.
                                        progress.unpublishedRecords[record.path] = record
                                    } else if canPublishIncrementally
                                        && progress.incrementallyPublishedChangeCount
                                            < Self.backgroundDirectoryIncrementalPublishLimit {
                                        upserts[record.path] = record
                                        progress.incrementallyPublishedChangeCount += 1
                                        publishedIncrementalChange = true
                                    } else {
                                        progress.unpublishedRecords[record.path] = record
                                    }
                                }
                                if publishedIncrementalChange {
                                    progress.incrementalPublishBatchCount += 1
                                }

                                if completesCurrentTraversal {
                                    progress.finalization = DirectoryUpdateFinalization(progress: progress)
                                }
                            }

                            if progress.finalization != nil {
                                let finalizationResult = advanceDirectoryUpdateFinalization(
                                    progress: progress,
                                    priority: request.priority,
                                    startedAt: updateStarted,
                                    generation: currentGeneration
                                )
                                visitedCount += finalizationResult.visitedCount
                                deferredDirectoryVisitCount += finalizationResult.visitedCount
                                if finalizationResult.visitedCount > 0 {
                                    request.clearRetryBackoffAfterProgress()
                                    request.markServiced(sequence: nextRefreshServiceSequence())
                                }
                                if finalizationResult.completed {
                                    stageCompletedDirectoryFinalization(
                                        progress,
                                        at: url,
                                        request: &request
                                    )
                                } else {
                                    request.directoryScanProgress = progress
                                    request.priority = effectiveRefreshPriority(request.priority)
                                    deferredRefreshes.append(request)
                                }
                            } else {
                                request.directoryScanProgress = progress
                                request.priority = effectiveRefreshPriority(request.priority)
                                deferredRefreshes.append(request)
                            }
                        } else {
                            let scanResult = scanConcurrently(
                                roots: [url],
                                exclusions: indexState.exclusions,
                                generation: currentGeneration,
                                checkpoint: nil,
                                operationStartedAt: updateStarted,
                                exclusionRootPaths: indexState.rootPaths,
                                writesCheckpoints: false,
                                publishesScanStatus: false,
                                publishesIntermediateSnapshots: false,
                                buildsRecordStore: false,
                                workerCount: Self.refreshScanWorkerCount(),
                                workerQoS: .utility,
                                progress: { _, _, _ in }
                            )
                            if let scanResult {
                                recordScanFrontierMetrics(scanResult.frontierMetrics, generation: currentGeneration)
                                exclusionInstrumentation.add(scanResult.exclusionInstrumentation)
                                visitedCount += scanResult.visited
                            }
                            concurrentlyScannedRecords = scanResult?.records
                        }
                        if let scannedRecords = concurrentlyScannedRecords {
                            requiresDirectoryReconciliation = true
                            reconciledDirectoryPrefixes.append(url.path)
                            for record in scannedRecords.values {
                                stageUpsertIfChanged(record)
                            }
                            stageDeletedRows(inSubtreeAt: url.path) { existingPath in
                                scannedRecords[existingPath] != nil
                            }
                        }
                    } else {
                        if request.directoryScanProgress != nil, !candidate.isDirectory {
                            // The former directory became a file or symlink while
                            // its traversal was suspended. Replace the old subtree
                            // and retain the current candidate as an upsert.
                            deletedPrefixes.append(url.path)
                        }
                        coverFollowUpWithCurrentObservation(&request)
                    }
                case .missing:
                    let fileDecision = exclusionDecision(
                        for: url,
                        exclusions: indexState.exclusions,
                        rootPaths: indexState.rootPaths,
                        query: exclusionQuery,
                        isDirectory: false,
                        instrumentation: &exclusionInstrumentation
                    )
                    let directoryDecision = exclusionDecision(
                        for: url,
                        exclusions: indexState.exclusions,
                        rootPaths: indexState.rootPaths,
                        query: exclusionQuery,
                        isDirectory: true,
                        instrumentation: &exclusionInstrumentation
                    )
                    guard fileDecision != .prune || directoryDecision != .prune else {
                        coverFollowUpWithCurrentObservation(&request)
                        return
                    }
                    deletedPrefixes.append(url.path)
                    coverFollowUpWithCurrentObservation(&request)
                case let .retry(error):
                    request.markServiced(sequence: nextRefreshServiceSequence())
                    request.deferAfterRetryFailure(
                        baseDelay: backgroundRefreshDrainBackoffDelay()
                    )
                    deferredRefreshes.append(request)
                    DiagnosticLogger.shared.log(
                        level: .warning,
                        category: "index",
                        event: "index.updatePathLookupDeferred",
                        fields: [
                            "errorCode": .publicInt(Int(error))
                        ],
                        diagnosticFields: [
                            "path": .path(url.path)
                        ]
                    )
                }
            }
        }

        guard isCurrentGeneration(currentGeneration) else {
            requeueRequestsAfterGenerationChange()
            return .none
        }
        var unresolvedDeletedPrefixes: [String] = []
        let hasCompletePathLookup = previousSnapshot.store.hasColumnarSidecars
        for prefix in deletedPrefixes {
            if let subtreeRows = previousSnapshot.store.rowIDs(inSubtreeAtPath: prefix) {
                deletedRows.formUnion(subtreeRows)
                continue
            }
            guard let rowID = previousSnapshot.store.rowID(forPath: prefix) else {
                if !hasCompletePathLookup {
                    unresolvedDeletedPrefixes.append(prefix)
                }
                continue
            }

            if previousSnapshot.store.isDirectory(at: rowID),
               !previousSnapshot.store.hasContiguousSubtreeRanges {
                unresolvedDeletedPrefixes.append(prefix)
                continue
            }

            let subtreeEnd = previousSnapshot.store.subtreeEnd(at: rowID)
            for deletedRow in rowID..<subtreeEnd {
                deletedRows.insert(deletedRow)
            }
        }

        if !unresolvedDeletedPrefixes.isEmpty {
            for rowID in 0..<previousSnapshot.count {
                guard !deletedRows.contains(rowID) else { continue }
                let path = previousSnapshot.store.path(at: rowID)
                if unresolvedDeletedPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                    deletedRows.insert(rowID)
                }
            }
        }

        let finalUpdatePriority = effectiveRefreshPriority(updatePriority)
        let deferredPaths = Set(deferredRefreshes.map(\.path))
        let explicitlyCompletedPaths = Set(completedRefreshes.map(\.path))
        let requiresDurableCompletion = completedRefreshes.contains { !$0.completions.isEmpty }
            || requests.contains { request in
                !deferredPaths.contains(request.path)
                    && !explicitlyCompletedPaths.contains(request.path)
                    && !request.completions.isEmpty
            }

        guard !upserts.isEmpty || !deletedRows.isEmpty else {
            let didApply = lock.withLock { () -> Bool in
                guard generation == currentGeneration else { return false }
                indexing = false
                reconciling = false
                updating = false
                phase = .ready
                if let preservedReadyStatus = updateContext.preservedReadyStatus {
                    status = preservedReadyStatus
                } else if !Self.shouldPreserveReadyStatusDuringNoopUpdate(status) {
                    status = "No file changes"
                }
                activeOperationStartedAt = nil
                lastUpdated = Date()
                completedRefreshBatches &+= 1
                return true
            }
            if !didApply {
                requeueRequestsAfterGenerationChange()
                return .none
            }
            publishStats()
            MemoryTelemetry.log(
                "update.noop",
                refreshBatchSize: paths.count,
                activeIndexJobs: currentActiveIndexJobCount()
            )
            recordIncrementalRefresh(duration: Date().timeIntervalSince(updateStarted))
            DiagnosticLogger.shared.log(
                category: "index",
                event: "index.updateNoop",
                fields: [
                    "pathCount": .publicInt(paths.count),
                    "durationSeconds": .publicDouble(Date().timeIntervalSince(updateStarted))
                ]
            )
            let completionReady: Bool
            if lock.withLock({ hasUnpersistedSnapshotChanges }) {
                if requiresDurableCompletion {
                    completionReady = persistSnapshot(
                        schedulesPathGramBuild: false,
                        priority: finalUpdatePriority.maintenancePriority
                    )
                } else {
                    scheduleDurabilityRetry()
                    completionReady = true
                }
            } else {
                completionReady = true
            }
            return makeUpdateResult(
                applied: true,
                largeOverlay: false,
                changedPathCount: 0,
                completionReady: completionReady
            )
        }

        if
            deletedRows.isEmpty,
            previousSnapshot.count <= Self.interactiveOverlayOptimizationRecordLimit,
            let updatedSnapshot = previousSnapshot.updatingMetadata(for: upserts)
        {
            let changedPathCount = upserts.count
            let didApply = lock.withLock { () -> Bool in
                guard generation == currentGeneration else { return false }
                searchSnapshot = updatedSnapshot
                searchSnapshotRevision &+= 1
                status = "Updated \(changedPathCount) changed path\(changedPathCount == 1 ? "" : "s")"
                phase = .ready
                indexing = false
                reconciling = false
                updating = false
                discoveredCount = updatedSnapshot.resultCount
                searchableCount = updatedSnapshot.resultCount
                optimizedCount = updatedSnapshot.isOptimizedForSearch ? updatedSnapshot.resultCount : 0
                recordsByPath.removeAll(keepingCapacity: false)
                lastUpdated = Date()
                activeOperationStartedAt = nil
                completedRefreshBatches &+= 1
                return true
            }
            if !didApply {
                requeueRequestsAfterGenerationChange()
                return .none
            }

            publishStats()
            let completionReady: Bool
            if lock.withLock({ structuralDelta != nil }) {
                switch persistStructuralDeltaChanges(
                    upserts: Array(upserts.values),
                    tombstonedPaths: [],
                    previousSnapshot: previousSnapshot
                ) {
                case .saved:
                    scheduleStructuralDeltaCompactionIfNeeded(updatedSnapshot)
                    completionReady = true
                case .unavailable:
                    if requiresDurableCompletion {
                        completionReady = persistSnapshot(
                            schedulesPathGramBuild: false,
                            priority: finalUpdatePriority.maintenancePriority
                        )
                        if !completionReady {
                            markSnapshotDurabilityPending()
                        }
                    } else {
                        markSnapshotDurabilityPending(schedulesRetry: false)
                        scheduleMetadataOverlayPersistIfReasonable(
                            updatedSnapshot,
                            changedPathCount: changedPathCount,
                            priority: finalUpdatePriority
                        )
                        completionReady = true
                    }
                case .failed:
                    markSnapshotDurabilityPending()
                    scheduleRefreshPersistIfReasonable(updatedSnapshot, priority: .background)
                    completionReady = !requiresDurableCompletion
                }
            } else if requiresDurableCompletion {
                completionReady = persistSnapshot(
                    schedulesPathGramBuild: false,
                    priority: finalUpdatePriority.maintenancePriority
                )
                if !completionReady {
                    markSnapshotDurabilityPending()
                }
            } else {
                markSnapshotDurabilityPending(schedulesRetry: false)
                scheduleMetadataOverlayPersistIfReasonable(
                    updatedSnapshot,
                    changedPathCount: changedPathCount,
                    priority: finalUpdatePriority
                )
                completionReady = true
            }
            MemoryTelemetry.log(
                "update.metadataApplied",
                records: RecordCollectionMetrics(recordCount: updatedSnapshot.count, totalPathBytes: 0, maxPathBytes: 0),
                structures: updatedSnapshot.diagnostics,
                refreshBatchSize: paths.count,
                activeIndexJobs: currentActiveIndexJobCount()
            )
            DiagnosticLogger.shared.log(
                category: "index",
                event: "index.updateMetadataApplied",
                fields: [
                    "pathCount": .publicInt(paths.count),
                    "upsertCount": .publicInt(upserts.count),
                    "recordCount": .publicInt(updatedSnapshot.resultCount),
                    "requiresDirectoryReconciliation": .publicBool(requiresDirectoryReconciliation),
                    "durationSeconds": .publicDouble(Date().timeIntervalSince(updateStarted))
                ]
            )
            return makeUpdateResult(
                applied: true,
                largeOverlay: false,
                changedPathCount: changedPathCount,
                completionReady: completionReady
            )
        }

        for path in upserts.keys {
            if let rowID = previousSnapshot.store.rowID(forPath: path) {
                deletedRows.insert(rowID)
            }
        }

        let tombstonedPaths = deletedRows.compactMap { rowID -> String? in
            let path = previousSnapshot.store.path(at: rowID)
            return upserts[path] == nil ? path : nil
        }
        let changedPathCount = upserts.count + tombstonedPaths.count
        let isLargeOverlayUpdate = requiresDirectoryReconciliation
            || changedPathCount > largeOverlayChangedPathThreshold()
        let overlayStore = OverlayRecordStore(
            base: previousSnapshot.store,
            upserts: Array(upserts.values),
            deletedRows: deletedRows
        )
        let shouldOptimizeOverlay = previousSnapshot.isOptimizedForSearch
            && !isLargeOverlayUpdate
            && finalUpdatePriority == .interactive
            && previousSnapshot.count <= Self.interactiveOverlayOptimizationRecordLimit
        let snapshot = SearchSnapshot(
            store: overlayStore,
            buildsSearchStructures: shouldOptimizeOverlay,
            buildsPathGramIndex: false,
            optimizedSortColumns: currentOptimizedSortColumns(),
            buildsAdditionalSortOrders: false,
            prefersDegradedSearch: !shouldOptimizeOverlay
                && (isLargeOverlayUpdate
                    || finalUpdatePriority == .background
                    || previousSnapshot.count > Self.interactiveOverlayOptimizationRecordLimit)
        )
        let compositeInputs = lock.withLock {
            (
                previousState: compositeSearchState,
                optimizedBase: compositeSearchState?.base.sourceSnapshot
                    ?? optimizedSearchFallbackSnapshot,
                roots: roots
            )
        }
        let indexedCompositeState = makeCompositeSearchState(
            logicalSnapshot: snapshot,
            optimizedBase: compositeInputs.optimizedBase,
            roots: compositeInputs.roots,
            previousState: compositeInputs.previousState,
            changedUpserts: Array(upserts.values),
            changedTombstonedPaths: tombstonedPaths
        )

        let didApply = lock.withLock { () -> Bool in
            guard generation == currentGeneration else { return false }
            searchSnapshot = snapshot
            compositeSearchState = indexedCompositeState
            searchSnapshotRevision &+= 1
            status = "Updated \(changedPathCount) changed path\(changedPathCount == 1 ? "" : "s")"
            phase = .ready
            indexing = false
            reconciling = false
            updating = false
            discoveredCount = snapshot.resultCount
            searchableCount = snapshot.resultCount
            optimizedCount = snapshot.isOptimizedForSearch || indexedCompositeState != nil
                ? snapshot.resultCount
                : 0
            recordsByPath.removeAll(keepingCapacity: false)
            lastUpdated = Date()
            activeOperationStartedAt = nil
            completedRefreshBatches &+= 1
            return true
        }
        if !didApply {
            requeueRequestsAfterGenerationChange()
            return .none
        }

        publishStats()
        let completionReady: Bool
        switch persistStructuralDeltaChanges(
            upserts: Array(upserts.values),
            tombstonedPaths: tombstonedPaths,
            previousSnapshot: previousSnapshot
        ) {
        case .saved:
            scheduleStructuralDeltaCompactionIfNeeded(snapshot)
            completionReady = true
        case .unavailable:
            if requiresDurableCompletion {
                completionReady = persistSnapshot(
                    schedulesPathGramBuild: false,
                    priority: finalUpdatePriority.maintenancePriority
                )
                if !completionReady {
                    markSnapshotDurabilityPending()
                }
            } else {
                markSnapshotDurabilityPending(schedulesRetry: false)
                scheduleRefreshPersistIfReasonable(
                    snapshot,
                    immediateLargeOverlay: isLargeOverlayUpdate,
                    priority: finalUpdatePriority
                )
                completionReady = true
            }
        case .failed:
            markSnapshotDurabilityPending()
            scheduleRefreshPersistIfReasonable(
                snapshot,
                immediateLargeOverlay: isLargeOverlayUpdate,
                priority: .background
            )
            completionReady = !requiresDurableCompletion
        }
        MemoryTelemetry.log(
            "update.overlayApplied",
            records: RecordCollectionMetrics(recordCount: snapshot.count, totalPathBytes: 0, maxPathBytes: 0),
            structures: snapshot.diagnostics,
            refreshBatchSize: paths.count,
            activeIndexJobs: currentActiveIndexJobCount()
        )
        recordIncrementalRefresh(duration: Date().timeIntervalSince(updateStarted))
        DiagnosticLogger.shared.log(
            category: "index",
            event: "index.updateOverlayApplied",
            fields: [
                "pathCount": .publicInt(paths.count),
                "upsertCount": .publicInt(upserts.count),
                "deletedPrefixCount": .publicInt(deletedPrefixes.count),
                "changedPathCount": .publicInt(changedPathCount),
                "recordCount": .publicInt(snapshot.resultCount),
                "requiresDirectoryReconciliation": .publicBool(requiresDirectoryReconciliation),
                "largeOverlay": .publicBool(isLargeOverlayUpdate),
                "optimizedOverlay": .publicBool(snapshot.isOptimizedForSearch),
                "priority": .publicString(updatePriority.rawValue),
                "deferredPathCount": .publicInt(deferredRefreshes.count),
                "durationSeconds": .publicDouble(Date().timeIntervalSince(updateStarted))
            ]
        )
        return makeUpdateResult(
            applied: true,
            largeOverlay: isLargeOverlayUpdate,
            changedPathCount: changedPathCount,
            completionReady: completionReady
        )
    }

    private func advanceDirectoryUpdateFinalization(
        progress: DirectoryUpdateScanProgress,
        priority: IndexWorkPriority,
        startedAt: Date,
        generation currentGeneration: UInt64
    ) -> DirectoryUpdateFinalizationResult {
        guard let finalization = progress.finalization else {
            return DirectoryUpdateFinalizationResult(completed: false, visitedCount: 0)
        }
        guard isCurrentGeneration(currentGeneration) else {
            return DirectoryUpdateFinalizationResult(completed: false, visitedCount: 0)
        }
        if finalization.phase == .readyToCommit {
            return DirectoryUpdateFinalizationResult(completed: true, visitedCount: 0)
        }

        let deadline = backgroundDirectoryScanDeadline(for: priority, startedAt: startedAt)
        let maximumWorkCount = backgroundDirectoryFinalizationLimit(for: priority)
        var visitedCount = 0

        func canContinue() -> Bool {
            guard isCurrentGeneration(currentGeneration) else { return false }
            if maximumWorkCount.map({ visitedCount >= $0 }) == true {
                return false
            }
            return deadline.map { Date() < $0 } ?? true
        }

        func remainingWorkCount() -> Int {
            maximumWorkCount.map { max($0 - visitedCount, 0) } ?? Int.max
        }

        while canContinue() {
            switch finalization.phase {
            case .baselineRows:
                let batchLimit = min(
                    Self.directoryFinalizationCursorBatchSize,
                    remainingWorkCount()
                )
                guard batchLimit > 0,
                      let batch = finalization.baselineCursor.nextBatch(
                        maximumVisitedRows: batchLimit
                      ) else {
                    if finalization.baselineCursor.isComplete {
                        finalization.phase = .unpublishedUpserts
                        continue
                    }
                    return DirectoryUpdateFinalizationResult(
                        completed: false,
                        visitedCount: visitedCount
                    )
                }

                let baselineStore = progress.baselineStore
                if batch.includesEveryRow {
                    finalization.matchingBaselineRowsVisited += batch.rowRange.count
                    progress.seenBaselineRows.forEachUnset(in: batch.rowRange) { rowID in
                        let path = baselineStore.path(at: rowID)
                        finalization.materializedDeletionPathCount += 1
                        guard !progress.isSuperseded(path) else { return }
                        finalization.deletionPaths.append(path)
                    }
                } else {
                    finalization.matchingBaselineRowsVisited += batch.forEachMatchingRow { rowID in
                        guard !progress.seenBaselineRows.contains(rowID) else { return }
                        let path = baselineStore.path(at: rowID)
                        finalization.materializedDeletionPathCount += 1
                        guard !progress.isSuperseded(path) else { return }
                        finalization.deletionPaths.append(path)
                    }
                }
                finalization.baselineRowsVisited += batch.rowRange.count
                visitedCount += batch.rowRange.count
                if batch.isComplete {
                    finalization.phase = .unpublishedUpserts
                }

            case .unpublishedUpserts:
                let chunkLimit = min(
                    Self.directoryFinalizationCursorBatchSize,
                    remainingWorkCount()
                )
                guard chunkLimit > 0 else {
                    return DirectoryUpdateFinalizationResult(
                        completed: false,
                        visitedCount: visitedCount
                    )
                }

                var processedCount = 0
                while processedCount < chunkLimit,
                      finalization.unpublishedRecordIndex
                        != finalization.unpublishedRecords.endIndex {
                    let currentIndex = finalization.unpublishedRecordIndex
                    let path = finalization.unpublishedRecords[currentIndex].key
                    finalization.unpublishedRecordIndex = finalization.unpublishedRecords.index(
                        after: currentIndex
                    )
                    finalization.upsertsVisited += 1
                    visitedCount += 1
                    processedCount += 1
                    if !progress.isSuperseded(path) {
                        finalization.preparedUpsertPaths.append(path)
                    }
                }
                if finalization.unpublishedRecordIndex == finalization.unpublishedRecords.endIndex {
                    finalization.phase = .readyToCommit
                    return DirectoryUpdateFinalizationResult(
                        completed: false,
                        visitedCount: visitedCount
                    )
                }

            case .readyToCommit:
                preconditionFailure("Ready finalization should commit in its next update slice")
            }
        }

        return DirectoryUpdateFinalizationResult(
            completed: false,
            visitedCount: visitedCount
        )
    }

    private func scanDirectoryForUpdate(
        progress: DirectoryUpdateScanProgress,
        exclusions: FileExclusionRules,
        rootPaths: [String],
        query: FileExclusionQuery?,
        requestedPriority: IndexWorkPriority,
        startedAt: Date,
        maximumVisitCount: Int?,
        maximumEntryCount: Int?,
        generation currentGeneration: UInt64
    ) -> DirectoryUpdateScanResult? {
        let volumeNameCache = ScanVolumeNameCache()
        var records: [String: FileRecord] = [:]
        var visitedCount = 0
        var readEntryCount = 0
        var checksDeadlineBeforeNextEntry = true
        var encounteredRetryError = false
        var exclusionInstrumentation = FileExclusionQuery.Instrumentation()

        func incompleteResult() -> DirectoryUpdateScanResult {
            DirectoryUpdateScanResult(
                records: records,
                completed: false,
                visitedCount: visitedCount,
                readEntryCount: readEntryCount,
                encounteredRetryError: encounteredRetryError,
                exclusionInstrumentation: exclusionInstrumentation
            )
        }

        func reachedDeadline() -> Bool {
            backgroundDirectoryScanDeadline(
                for: requestedPriority,
                startedAt: startedAt
            ).map { Date() >= $0 } ?? false
        }

        // Retry a failed URL only after the healthy work that was already queued
        // beside it. Otherwise appending it back to this LIFO stack makes the
        // same persistent failure the first item selected on every slice.
        progress.activateDeferredRetriesIfNeeded()

        while progress.activeEnumeration != nil || !progress.pendingURLs.isEmpty {
            guard isCurrentGeneration(currentGeneration) else { return nil }

            if let cursor = progress.activeEnumeration {
                if progress.isSuperseded(cursor.directoryPath) {
                    cursor.close()
                    progress.activeEnumeration = nil
                    continue
                }

                if maximumEntryCount.map({ readEntryCount >= $0 }) == true {
                    return incompleteResult()
                }
                if checksDeadlineBeforeNextEntry || readEntryCount.isMultiple(of: 64) {
                    checksDeadlineBeforeNextEntry = false
                    if reachedDeadline() {
                        return incompleteResult()
                    }
                }

                guard let stream = cursor.stream else {
                    progress.activeEnumeration = nil
                    progress.deferForRetry(cursor.directory)
                    encounteredRetryError = true
                    continue
                }

                errno = 0
                guard let entry = readdir(stream) else {
                    let readError = errno
                    if readError == 0 {
                        let children = cursor.takeChildrenAndClose()
                        progress.activeEnumeration = nil
                        progress.pendingURLs.append(contentsOf: children.reversed())
                        continue
                    }

                    // A partial directory listing is not complete coverage. Drop
                    // every child from that attempt and retry the directory later.
                    cursor.close()
                    progress.activeEnumeration = nil
                    progress.deferForRetry(cursor.directory)
                    encounteredRetryError = true
                    continue
                }

                readEntryCount += 1
                cursor.readEntryCount += 1
                guard let entryInfo = Self.directoryEntryInfo(entry) else { continue }
                let name = entryInfo.name
                guard name != "." && name != ".." else { continue }
                if entryInfo.isDirectory,
                   exclusions.canPruneDirectoryComponentBeforeStat(name) {
                    exclusionInstrumentation.fastPruneDirectoryCount += 1
                    continue
                }
                cursor.children.append(
                    cursor.directory.appendingPathComponent(name, isDirectory: entryInfo.isDirectory)
                )
                continue
            }

            if reachedDeadline()
                || maximumVisitCount.map({ visitedCount >= $0 }) == true {
                return incompleteResult()
            }

            guard let url = progress.pendingURLs.popLast() else { continue }
            visitedCount += 1

            if progress.isSuperseded(url.path) {
                continue
            }

            let candidate: FileSystemRecordCandidate
            switch fileSystemRecordLookup(for: url, volumeNameCache: volumeNameCache) {
            case let .record(recordCandidate):
                candidate = recordCandidate
            case .missing:
                let missingPath = url.path
                progress.recordMissingPath(missingPath)
                progress.unpublishedRecords.removeValue(forKey: missingPath)
                continue
            case .retry:
                progress.deferForRetry(url)
                encounteredRetryError = true
                continue
            }
            let decision = exclusionDecision(
                for: candidate.url,
                exclusions: exclusions,
                rootPaths: rootPaths,
                query: query,
                isDirectory: candidate.isDirectory,
                instrumentation: &exclusionInstrumentation
            )
            guard decision != .prune else { continue }

            if decision.shouldIndex {
                progress.recordObservedPath(candidate.record.path)
                records[candidate.record.path] = candidate.record
            }

            guard candidate.isDirectory, !candidate.isSymlink, decision.shouldDescend else {
                continue
            }

#if DEBUG
            if consumeDirectoryUpdateEnumerationFailureForTesting(at: candidate.path) {
                progress.deferForRetry(candidate.url)
                encounteredRetryError = true
                continue
            }
#endif

            guard let stream = openDirectoryStream(candidate.url) else {
                progress.deferForRetry(candidate.url)
                encounteredRetryError = true
                continue
            }
            progress.activeEnumeration = DirectoryUpdateEnumerationCursor(
                directory: candidate.url,
                stream: stream
            )
            checksDeadlineBeforeNextEntry = true
        }

        guard progress.deferredRetryURLs.isEmpty else {
            return incompleteResult()
        }

        return DirectoryUpdateScanResult(
            records: records,
            completed: true,
            visitedCount: visitedCount,
            readEntryCount: readEntryCount,
            encounteredRetryError: false,
            exclusionInstrumentation: exclusionInstrumentation
        )
    }

    private func nextRefreshServiceSequence() -> UInt64 {
        lock.withLock {
            refreshServiceSequence &+= 1
            return refreshServiceSequence
        }
    }

    private func consumeDirectoryUpdateEnumerationFailureForTesting(at path: String) -> Bool {
        guard let remaining = directoryUpdateEnumerationFailuresForTesting[path], remaining > 0 else {
            return false
        }
        if remaining == 1 {
            directoryUpdateEnumerationFailuresForTesting.removeValue(forKey: path)
        } else {
            directoryUpdateEnumerationFailuresForTesting[path] = remaining - 1
        }
        return true
    }

    private func consumeFileSystemLookupFailureForTesting(at path: String) -> Int32? {
        guard let failure = fileSystemLookupFailuresForTesting[path], failure.remaining > 0 else {
            return nil
        }
        if failure.remaining == 1 {
            fileSystemLookupFailuresForTesting.removeValue(forKey: path)
        } else {
            fileSystemLookupFailuresForTesting[path] = (failure.error, failure.remaining - 1)
        }
        return failure.error
    }

    private func enumerateShallowChildURLs(
        in directory: URL,
        prunesDirectoryNamed: ((String) -> Bool)? = nil,
        _ body: (URL) -> Bool
    ) -> ShallowDirectoryEnumerationResult {
        for attempt in 0..<Self.fullScanRetryLimit {
            guard let stream = openDirectoryStream(directory) else {
                let error = errno == 0 ? EIO : errno
                if error == ENOENT || error == ENOTDIR {
                    return .completed
                }
                if attempt + 1 == Self.fullScanRetryLimit {
                    return .retry(error: error)
                }
                continue
            }

            var result = ShallowDirectoryEnumerationResult.completed
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    let error = errno
                    if error != 0 {
                        result = .retry(error: error)
                    }
                    break
                }
                guard let entryInfo = Self.directoryEntryInfo(entry) else { continue }
                let name = entryInfo.name
                guard name != "." && name != ".." else { continue }
                if entryInfo.isDirectory, prunesDirectoryNamed?(name) == true {
                    continue
                }

                let child = directory.appendingPathComponent(name, isDirectory: entryInfo.isDirectory)
                guard body(child) else {
                    result = .stopped
                    break
                }
            }
            closedir(stream)

            if case .retry = result, attempt + 1 < Self.fullScanRetryLimit {
                continue
            }
            return result
        }

        return .retry(error: EIO)
    }

    private func retryingFileSystemRecordLookup(
        for url: URL,
        volumeNameCache: ScanVolumeNameCache
    ) -> FileSystemRecordLookup {
        var lastResult = FileSystemRecordLookup.retry(error: EIO)
        for _ in 0..<Self.fullScanRetryLimit {
            let result = fileSystemRecordLookup(for: url, volumeNameCache: volumeNameCache)
            switch result {
            case .record, .missing:
                return result
            case .retry:
                lastResult = result
            }
        }
        return lastResult
    }

    private func logFullScanTraversalFailure(path: String, error: Int32) {
        DiagnosticLogger.shared.log(
            level: .error,
            category: "index",
            event: "index.scanTraversalFailed",
            fields: [
                "error": .publicInt(Int(error)),
                "path": .path(path),
                "retryLimit": .publicInt(Self.fullScanRetryLimit)
            ]
        )
    }

    private func fileSystemRecordLookup(
        for url: URL,
        volumeNameCache: ScanVolumeNameCache
    ) -> FileSystemRecordLookup {
        let path = url.path
#if DEBUG
        if let error = consumeFileSystemLookupFailureForTesting(at: path) {
            return .retry(error: error)
        }
#endif
        var statBlock = stat()
        errno = 0
        let result = path.withCString { lstat($0, &statBlock) }
        guard result == 0 else {
            let error = errno
            return error == ENOENT || error == ENOTDIR
                ? .missing
                : .retry(error: error)
        }

        let isDirectory = Self.isDirectoryMode(statBlock.st_mode)
        let isSymlink = Self.isSymbolicLinkMode(statBlock.st_mode)
        let volumeName = volumeNameCache.volumeName(for: url, statBlock: statBlock)
        let record = FileRecord.fileIndexStatDerived(
            path: path,
            statBlock: statBlock,
            isDirectory: isDirectory,
            volumeName: volumeName
        )

        return .record(FileSystemRecordCandidate(
            url: url,
            path: path,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            record: record
        ))
    }

    private static func isDirectoryMode(_ mode: mode_t) -> Bool {
        mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    private static func isSymbolicLinkMode(_ mode: mode_t) -> Bool {
        mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
    }

    private static let direntRecordLengthOffset = MemoryLayout<dirent>.offset(of: \.d_reclen)!
    private static let direntNameLengthOffset = MemoryLayout<dirent>.offset(of: \.d_namlen)!
    private static let direntTypeOffset = MemoryLayout<dirent>.offset(of: \.d_type)!
    private static let direntNameOffset = MemoryLayout<dirent>.offset(of: \.d_name)!

    static func directoryEntryInfo(_ entry: UnsafeMutablePointer<dirent>) -> (name: String, isDirectory: Bool)? {
        let rawEntry = UnsafeRawPointer(entry)
        let recordByteCount = Int(rawEntry.load(
            fromByteOffset: Self.direntRecordLengthOffset,
            as: UInt16.self
        ))
        let nameByteCount = Int(rawEntry.load(
            fromByteOffset: Self.direntNameLengthOffset,
            as: UInt16.self
        ))
        let entryType = rawEntry.load(fromByteOffset: Self.direntTypeOffset, as: UInt8.self)
        let maximumNameByteCount = recordByteCount - Self.direntNameOffset
        guard recordByteCount >= Self.direntNameOffset,
              recordByteCount <= MemoryLayout<dirent>.size,
              nameByteCount > 0,
              nameByteCount <= maximumNameByteCount else {
            return nil
        }

        let nameBytes = UnsafeRawBufferPointer(
            start: rawEntry.advanced(by: Self.direntNameOffset),
            count: nameByteCount
        )
        return (
            name: String(decoding: nameBytes, as: UTF8.self),
            isDirectory: Int32(entryType) == DT_DIR
        )
    }

    private func updateIndexingProgress(status: String, indexedCount: Int) {
        lock.withLock {
            indexing = true
            reconciling = false
            updating = false
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
            records: RecordCollectionMetrics(recordCount: records.count, totalPathBytes: 0, maxPathBytes: 0),
            activeIndexJobs: currentActiveIndexJobCount()
        )

        let rootPaths = lock.withLock { roots }
        let snapshot = SearchSnapshot(
            records: Array(records.values),
            roots: rootPaths,
            buildsSearchStructures: !isIndexing,
            optimizedSortColumns: currentOptimizedSortColumns()
        )
        lock.withLock {
            recordsByPath = records
            searchSnapshot = snapshot
            searchSnapshotRevision &+= 1
            indexing = isIndexing
            reconciling = false
            updating = false
            phase = isIndexing ? .scanning : .ready
            discoveredCount = snapshot.resultCount
            searchableCount = snapshot.resultCount
            optimizedCount = isIndexing ? 0 : snapshot.resultCount
            self.status = status
            lastUpdated = Date()
            activeOperationStartedAt = isIndexing ? Date() : nil
            resumedFromCheckpoint = false
            if !isIndexing {
                completedSnapshotRebuilds &+= 1
            }
        }
        publishStats()

        MemoryTelemetry.log(
            isIndexing ? "snapshot.partial.applied" : "snapshot.final.applied",
            records: Self.countOnlyMetrics(for: snapshot.store),
            structures: snapshot.diagnostics,
            activeIndexJobs: currentActiveIndexJobCount()
        )
    }

    private func structuralDeltaCompactionThreshold(for delta: StructuralDelta) -> Int {
        largeOverlayPersistRecordLimitOverride
            ?? min(max(10_000, delta.baseIdentity.recordCount / 50), 50_000)
    }

    private func hasDurableStructuralDeltaBelowCompactionThresholdWithoutLock() -> Bool {
        guard !hasUnpersistedSnapshotChanges, let structuralDelta else { return false }
        return structuralDelta.changeCount < structuralDeltaCompactionThreshold(for: structuralDelta)
    }

    private func scheduleStructuralDeltaCompactionIfNeeded(_ snapshot: SearchSnapshot) {
        let deltaState = lock.withLock { structuralDelta }
        guard let deltaState else { return }

        let threshold = structuralDeltaCompactionThreshold(for: deltaState)
        guard deltaState.changeCount >= threshold else {
            DiagnosticLogger.shared.log(
                category: "index",
                event: "index.structuralDeltaCompactionDeferred",
                fields: [
                    "changeCount": .publicInt(deltaState.changeCount),
                    "threshold": .publicInt(threshold)
                ]
            )
            return
        }

        let configuredDelay = largeOverlayPersistDelayOverride != nil
            ? largeOverlayPersistDelay(immediateLargeOverlay: true)
            : backgroundOptimizationPersistDelay()
        let multipliedThreshold = threshold.multipliedReportingOverflow(
            by: Self.structuralDeltaCompactionImmediateChangeMultiplier
        )
        let immediateChangeThreshold = multipliedThreshold.overflow
            ? Int.max
            : multipliedThreshold.partialValue
        let deltaBytes = Self.allocatedFileSize(of: structuralDeltaStore.url)
        let requiresImmediateCompaction = largeOverlayPersistRecordLimitOverride == nil
            && (deltaState.changeCount >= immediateChangeThreshold
                || deltaBytes >= Self.structuralDeltaCompactionImmediateByteLimit)
        let delay = requiresImmediateCompaction ? 0 : configuredDelay
        let schedule = lock.withLock { () -> (
            revision: UInt64,
            writerConflictWarningDeadline: Date,
            escalated: Bool
        )? in
            if let writerConflictWarningDeadline = structuralDeltaCompactionWriterConflictWarningDeadline,
               structuralDeltaCompactionScheduledAt != nil {
                guard requiresImmediateCompaction, !structuralDeltaCompactionIsImmediate else {
                    return nil
                }
                structuralDeltaCompactionRevision &+= 1
                structuralDeltaCompactionIsImmediate = true
                return (structuralDeltaCompactionRevision, writerConflictWarningDeadline, true)
            }

            let scheduledAt = Date()
            structuralDeltaCompactionRevision &+= 1
            structuralDeltaCompactionScheduledAt = scheduledAt
            structuralDeltaCompactionIsImmediate = requiresImmediateCompaction
            let writerConflictWarningDeadline = scheduledAt.addingTimeInterval(
                max(Self.structuralDeltaCompactionWriterConflictWarningDelay, delay)
            )
            structuralDeltaCompactionWriterConflictWarningDeadline = writerConflictWarningDeadline
            return (structuralDeltaCompactionRevision, writerConflictWarningDeadline, false)
        }
        guard let schedule else {
            DiagnosticLogger.shared.log(
                category: "index",
                event: "index.structuralDeltaCompactionAlreadyScheduled",
                fields: [
                    "recordCount": .publicInt(snapshot.count),
                    "changeCount": .publicInt(deltaState.changeCount),
                    "deltaBytes": .publicUInt64(deltaBytes),
                    "immediate": .publicBool(requiresImmediateCompaction)
                ]
            )
            return
        }
        recordDeferredOptimization(reason: "structuralDeltaThreshold", delay: delay)
        DiagnosticLogger.shared.log(
            category: "index",
            event: "index.structuralDeltaCompactionScheduled",
            fields: [
                "recordCount": .publicInt(snapshot.count),
                "changeCount": .publicInt(deltaState.changeCount),
                "threshold": .publicInt(threshold),
                "deltaBytes": .publicUInt64(deltaBytes),
                "immediate": .publicBool(requiresImmediateCompaction),
                "escalated": .publicBool(schedule.escalated),
                "delaySeconds": .publicDouble(delay),
                "writerConflictWarningDeadlineSeconds": .publicDouble(
                    max(schedule.writerConflictWarningDeadline.timeIntervalSinceNow, 0)
                )
            ]
        )
        scheduleStructuralDeltaCompaction(
            revision: schedule.revision,
            delay: delay
        )
    }

    private func scheduleStructuralDeltaCompaction(revision: UInt64, delay: TimeInterval) {
        indexQueue.asyncAfter(deadline: .now() + max(delay, 0)) { [weak self] in
            self?.runStructuralDeltaCompaction(revision: revision)
        }
    }

    private func runStructuralDeltaCompaction(revision: UInt64) {
        let state = lock.withLock { () -> (
            isCurrent: Bool,
            hasDelta: Bool,
            hasConflictingWriter: Bool,
            writerConflictWarningDeadline: Date?
        ) in
            (
                structuralDeltaCompactionRevision == revision
                    && structuralDeltaCompactionScheduledAt != nil,
                structuralDelta != nil,
                activeDeferredOptimizationRevision != nil
                    || activePathGramBuildGeneration != nil,
                structuralDeltaCompactionWriterConflictWarningDeadline
            )
        }
        guard state.isCurrent else { return }
        guard state.hasDelta else {
            lock.withLock { clearStructuralDeltaCompactionWithoutLock() }
            return
        }

        // Queued background refreshes intentionally are not blockers: they were
        // the reason the old sliding persistence timer could starve forever.
        // Package writers remain blockers because they can race installation.
        if state.hasConflictingWriter {
            let retryDelay = Self.structuralDeltaCompactionRetryDelay
            DiagnosticLogger.shared.log(
                category: "index",
                event: "index.structuralDeltaCompactionDeferred",
                fields: [
                    "reason": .publicString("conflictingWriter"),
                    "writerConflictWarningReached": .publicBool(
                        state.writerConflictWarningDeadline.map { Date() >= $0 } ?? false
                    ),
                    "retryDelaySeconds": .publicDouble(retryDelay)
                ]
            )
            scheduleStructuralDeltaCompaction(revision: revision, delay: retryDelay)
            return
        }

        lock.withLock { persistRevision &+= 1 }
        let succeeded = persistSnapshot(
            forceMappedCheckpoint: true,
            priority: .background
        )
        if succeeded {
            lock.withLock { clearStructuralDeltaCompactionWithoutLock() }
        } else {
            scheduleStructuralDeltaCompaction(
                revision: revision,
                delay: Self.structuralDeltaCompactionRetryDelay
            )
        }
    }

    private func clearStructuralDeltaCompactionWithoutLock() {
        structuralDeltaCompactionRevision &+= 1
        structuralDeltaCompactionScheduledAt = nil
        structuralDeltaCompactionWriterConflictWarningDeadline = nil
        structuralDeltaCompactionIsImmediate = false
    }

    private func scheduleRefreshPersistIfReasonable(
        _ snapshot: SearchSnapshot,
        immediateLargeOverlay: Bool = false,
        priority: IndexWorkPriority = .interactive
    ) {
        if priority == .background, snapshot.store.kind == .overlay {
            let delay = backgroundOptimizationPersistDelay()
            recordDeferredOptimization(reason: "background", delay: delay)
            DiagnosticLogger.shared.log(
                category: "index",
                event: "index.optimizationDeferred",
                fields: [
                    "recordCount": .publicInt(snapshot.count),
                    "storeKind": .publicString(snapshot.store.kind.rawValue),
                    "optimizedForSearch": .publicBool(snapshot.isOptimizedForSearch),
                    "delaySeconds": .publicDouble(delay),
                    "reason": .publicString("background")
                ]
            )
            schedulePersist(delay: delay, priority: .background)
            return
        }

        if snapshot.store.kind == .overlay, snapshot.count > largeOverlayPersistRecordLimit() {
            let delay = largeOverlayPersistDelay(immediateLargeOverlay: immediateLargeOverlay)
            MemoryTelemetry.log(
                "refresh.persist.scheduledLargeOverlay",
                records: Self.countOnlyMetrics(for: snapshot.store),
                structures: snapshot.diagnostics,
                activeIndexJobs: currentActiveIndexJobCount()
            )
            DiagnosticLogger.shared.log(
                category: "index",
                event: "index.snapshotPersistScheduled",
                fields: [
                    "recordCount": .publicInt(snapshot.count),
                    "storeKind": .publicString(snapshot.store.kind.rawValue),
                    "delaySeconds": .publicDouble(delay)
                ]
            )
            schedulePersist(delay: delay, priority: priority.maintenancePriority)
            return
        }

        schedulePersist(priority: priority.maintenancePriority)
    }

    private enum PersistMode {
        case automatic
        case metadataOverlayCheckpoint
    }

    private func automaticPersistSuppression(
        for mode: PersistMode
    ) -> (changeCount: Int, threshold: Int)? {
        guard case .automatic = mode else { return nil }
        return lock.withLock {
            guard !hasUnpersistedSnapshotChanges, let structuralDelta else { return nil }
            let threshold = structuralDeltaCompactionThreshold(for: structuralDelta)
            guard structuralDelta.changeCount < threshold else { return nil }
            return (structuralDelta.changeCount, threshold)
        }
    }

    private enum StructuralDeltaPersistenceResult: Equatable {
        case saved
        case unavailable
        case failed
    }

    private struct ScheduledPersistBacklog {
        let refreshPathCount: Int
        let reconciliationScopeCount: Int
        let refreshDrainScheduled: Bool
        let reconciliationDrainScheduled: Bool
        let hasActiveIndexWork: Bool
        let hasDeferredOptimization: Bool

        var requiresDeferral: Bool {
            refreshPathCount > 0
                || reconciliationScopeCount > 0
                || refreshDrainScheduled
                || reconciliationDrainScheduled
                || hasActiveIndexWork
                || hasDeferredOptimization
        }
    }

    private func scheduleMetadataOverlayPersistIfReasonable(
        _ snapshot: SearchSnapshot,
        changedPathCount: Int,
        priority: IndexWorkPriority = .interactive
    ) {
        guard
            let replacingStore = snapshot.store as? ReplacingRecordStore,
            replacingStore.metadataBaseStoreKind == .mapped
        else {
            scheduleRefreshPersistIfReasonable(snapshot, priority: priority)
            return
        }

        let replacementCount = replacingStore.metadataReplacementCount
        guard replacementCount <= metadataOverlayPersistLimit() else {
            let checkpointDelay = priority == .background ? backgroundOptimizationPersistDelay() : largeOverlayPersistDelay()
            scheduleMetadataOverlayCheckpoint(
                snapshot,
                replacementCount: replacementCount,
                changedPathCount: changedPathCount,
                reason: "replacementLimit",
                delay: checkpointDelay,
                priority: priority.maintenancePriority
            )
            return
        }

        let delay = metadataOverlayPersistDelay()
        MemoryTelemetry.log(
            "metadataOverlay.persist.scheduled",
            records: Self.countOnlyMetrics(for: snapshot.store),
            structures: snapshot.diagnostics,
            refreshBatchSize: changedPathCount,
            activeIndexJobs: currentActiveIndexJobCount()
        )
        DiagnosticLogger.shared.log(
            category: "index",
            event: "index.metadataOverlayPersistScheduled",
            fields: [
                "recordCount": .publicInt(snapshot.count),
                "replacementCount": .publicInt(replacementCount),
                "changedPathCount": .publicInt(changedPathCount),
                "delaySeconds": .publicDouble(delay)
            ]
        )
        schedulePersist(delay: delay, priority: priority.maintenancePriority)
    }

    private func scheduleMetadataOverlayCheckpoint(
        _ snapshot: SearchSnapshot,
        replacementCount: Int,
        changedPathCount: Int,
        reason: String,
        delay: TimeInterval,
        priority: IndexMaintenancePriority = .interactive
    ) {
        recordDeferredCheckpoint(reason: reason, delay: delay)
        MemoryTelemetry.log(
            "metadataOverlay.checkpoint.scheduled",
            records: Self.countOnlyMetrics(for: snapshot.store),
            structures: snapshot.diagnostics,
            refreshBatchSize: changedPathCount,
            activeIndexJobs: currentActiveIndexJobCount()
        )
        DiagnosticLogger.shared.log(
            category: "index",
            event: "index.metadataOverlayCheckpointScheduled",
            fields: [
                "recordCount": .publicInt(snapshot.count),
                "replacementCount": .publicInt(replacementCount),
                "changedPathCount": .publicInt(changedPathCount),
                "reason": .publicString(reason),
                "delaySeconds": .publicDouble(delay)
            ]
        )
        schedulePersist(delay: delay, mode: .metadataOverlayCheckpoint, priority: priority)
    }

    private func schedulePersist(
        delay: TimeInterval = 1.5,
        mode: PersistMode = .automatic,
        priority: IndexMaintenancePriority = .interactive
    ) {
        let revision = lock.withLock { () -> UInt64 in
            persistRevision &+= 1
            return persistRevision
        }

        indexQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isPersistRevisionCurrent(revision) else { return }
            if let suppression = self.automaticPersistSuppression(for: mode) {
                DiagnosticLogger.shared.log(
                    category: "index",
                    event: "index.snapshotPersistSkipped",
                    fields: [
                        "changeCount": .publicInt(suppression.changeCount),
                        "reason": .publicString("durableStructuralDelta"),
                        "threshold": .publicInt(suppression.threshold)
                    ]
                )
                return
            }
            if self.deferScheduledPersistIfMaintenanceIsPending(mode: mode, priority: priority) {
                return
            }
            self.persistSnapshot(
                forceMappedCheckpoint: mode == .metadataOverlayCheckpoint,
                priority: priority
            )
        }
    }

    private func deferScheduledPersistIfMaintenanceIsPending(
        mode: PersistMode,
        priority: IndexMaintenancePriority
    ) -> Bool {
        let backlog = lock.withLock {
            ScheduledPersistBacklog(
                refreshPathCount: pendingRefreshPaths.count,
                reconciliationScopeCount: pendingReconciliationIncludesAllRoots
                    ? roots.count
                    : pendingReconciliationPaths.count,
                refreshDrainScheduled: isRefreshDrainScheduled,
                reconciliationDrainScheduled: isReconciliationDrainScheduled,
                hasActiveIndexWork: indexing || reconciling || updating,
                hasDeferredOptimization: activeDeferredOptimizationRevision != nil
            )
        }
        guard backlog.requiresDeferral else { return false }

        let configuredDelay = priority == .background
            ? backgroundOptimizationPersistDelay()
            : largeOverlayPersistDelay()
        let retryDelay = max(configuredDelay, 0.25)
        DiagnosticLogger.shared.log(
            category: "index",
            event: "index.snapshotPersistDeferred",
            fields: [
                "pendingRefreshPathCount": .publicInt(backlog.refreshPathCount),
                "pendingReconciliationScopeCount": .publicInt(backlog.reconciliationScopeCount),
                "refreshDrainScheduled": .publicBool(backlog.refreshDrainScheduled),
                "reconciliationDrainScheduled": .publicBool(backlog.reconciliationDrainScheduled),
                "activeIndexWork": .publicBool(backlog.hasActiveIndexWork),
                "deferredOptimizationActive": .publicBool(backlog.hasDeferredOptimization),
                "retryDelaySeconds": .publicDouble(retryDelay),
                "priority": .publicString(priority.rawValue)
            ]
        )
        schedulePersist(delay: retryDelay, mode: mode, priority: priority)
        return true
    }

    @discardableResult
    private func persistSnapshot(
        schedulesPathGramBuild: Bool = true,
        forceMappedCheckpoint: Bool = false,
        priority: IndexMaintenancePriority = .interactive
    ) -> Bool {
        let started = Date()
        let maintenanceMeasurement = MaintenanceMeasurement(startedAt: started)
        let jobID = beginIndexJob("persist")
        let persistenceGeneration = beginPersistenceStatus(startedAt: started)
        defer {
            endIndexJob("persist", jobID: jobID)
            finishPersistenceStatus(generationAtStart: persistenceGeneration)
        }

        let snapshotData = lock.withLock {
            (
                roots: roots,
                exclusionPatterns: exclusionRules.patterns,
                snapshot: searchSnapshot,
                optimizedSortColumns: optimizedSortColumns
            )
        }

        let metrics = Self.countOnlyMetrics(for: snapshotData.snapshot.store)
        MemoryTelemetry.log(
            "snapshot.persist.begin",
            records: metrics,
            structures: lock.withLock { searchSnapshot.diagnostics },
            activeIndexJobs: currentActiveIndexJobCount()
        )
        DiagnosticLogger.shared.log(
            category: "index",
            event: "index.snapshotPersistBegin",
            fields: [
                "rootCount": .publicInt(snapshotData.roots.count),
                "recordCount": .publicInt(metrics.recordCount),
                "storeKind": .publicString(snapshotData.snapshot.store.kind.rawValue)
            ]
        )

        do {
            if
                !forceMappedCheckpoint,
                let replacingStore = snapshotData.snapshot.store as? ReplacingRecordStore,
                replacingStore.metadataBaseStoreKind == .mapped,
                replacingStore.metadataReplacementCount <= metadataOverlayPersistLimit()
            {
                try persistMetadataOverlay(
                    replacingStore: replacingStore,
                    snapshot: snapshotData.snapshot,
                    started: started,
                    priority: priority
                )
                recordMaintenance(maintenanceMeasurement.operation(
                    kind: .metadataOverlayPersist,
                    priority: priority,
                    records: replacingStore.metadataReplacementCount
                ))
                completePendingDurabilityCompletions()
                return true
            }

            var persistedSnapshot: SearchSnapshot?
            _ = try persistMappedSnapshot(
                roots: snapshotData.roots,
                exclusionPatterns: snapshotData.exclusionPatterns,
                store: snapshotData.snapshot.store
            ) { mappedStore, packageURL in
                let existingPathGramIndex = snapshotData.snapshot.store.kind == .mapped
                    ? snapshotData.snapshot.gramIndex
                    : nil
                let snapshot = snapshotData.snapshot.rebasedForMappedPersistence(
                    store: mappedStore,
                    completePathGramIndex: existingPathGramIndex,
                    optimizedSortColumns: snapshotData.optimizedSortColumns
                )
                try persistSearchStructures(for: snapshot, packageURL: packageURL)
                persistedSnapshot = snapshot
            }
            guard let persistedSnapshot else {
                throw CocoaError(.fileWriteUnknown)
            }
            MemoryTelemetry.log(
                "snapshot.persist.finished",
                records: metrics,
                structures: persistedSnapshot.diagnostics,
                activeIndexJobs: currentActiveIndexJobCount()
            )
            DiagnosticLogger.shared.log(
                category: "index",
                event: "index.snapshotPersistFinished",
                fields: [
                    "recordCount": .publicInt(metrics.recordCount),
                    "optimizedForSearch": .publicBool(persistedSnapshot.isOptimizedForSearch),
                    "modifiedOrderCount": .publicInt(persistedSnapshot.modifiedDescending.count),
                    "visibleModifiedOrderCount": .publicInt(persistedSnapshot.visibleModifiedDescending.count),
                    "nameGramPostingCount": .publicInt(persistedSnapshot.diagnostics.nameGramPostingCount),
                    "componentGramPostingCount": .publicInt(persistedSnapshot.diagnostics.componentGramPostingCount),
                    "pathGramPostingCount": .publicInt(persistedSnapshot.diagnostics.pathGramPostingCount),
                    "durationSeconds": .publicDouble(Date().timeIntervalSince(started)),
                    "pendingRefreshPathCount": .publicInt(lock.withLock { pendingRefreshPaths.count })
                ]
            )
            var pathBuildRequest: (SearchSnapshot, UInt64, UInt64)?
            if snapshotData.snapshot.store.kind == .overlay || snapshotData.snapshot.store.kind == .heapPaged {
                lock.withLock {
                    searchSnapshot = persistedSnapshot
                    searchSnapshotRevision &+= 1
                    recordsByPath.removeAll(keepingCapacity: false)
                    discoveredCount = persistedSnapshot.resultCount
                    searchableCount = persistedSnapshot.resultCount
                    optimizedCount = persistedSnapshot.isOptimizedForSearch ? persistedSnapshot.resultCount : 0
                    lastUpdated = Date()
                    if schedulesPathGramBuild, persistedSnapshot.gramIndex == nil {
                        pathBuildRequest = (persistedSnapshot, generation, searchSnapshotRevision)
                    }
                }
                publishStats()
            }
            if let pathBuildRequest {
                startPathGramBuildIfNeeded(
                    snapshot: pathBuildRequest.0,
                    packageURL: snapshotURL,
                    generation: pathBuildRequest.1,
                    baseSnapshotRevision: pathBuildRequest.2
                )
            }
            clearDeferredMaintenanceMarkers()
            recordMaintenance(maintenanceMeasurement.operation(
                kind: .snapshotPersist,
                priority: priority,
                records: metrics.recordCount
            ))
            completePendingDurabilityCompletions()
            return true
        } catch {
            lock.withLock {
                phase = .failed
                indexing = false
                reconciling = false
                updating = false
                status = "Could not persist index: \(error.localizedDescription)"
                lastUpdated = Date()
            }
            recordPersistFailure()
            DiagnosticLogger.shared.log(
                level: .error,
                category: "index",
                event: "index.snapshotPersistFailed",
                fields: [
                    "recordCount": .publicInt(metrics.recordCount),
                    "durationSeconds": .publicDouble(Date().timeIntervalSince(started)),
                    "error": .errorText(error.localizedDescription)
                ]
            )
            publishStats()
            if lock.withLock({ hasUnpersistedSnapshotChanges }) {
                scheduleDurabilityRetry()
            }
            return false
        }
    }

    private func beginPersistenceStatus(startedAt: Date) -> UInt64 {
        let generationAtStart = lock.withLock { () -> UInt64 in
            let generationAtStart = generation
            indexing = true
            reconciling = false
            updating = false
            phase = .saving
            status = "Saving index"
            activeOperationStartedAt = startedAt
            lastUpdated = Date()
            return generationAtStart
        }
        publishStats()
        return generationAtStart
    }

    private func finishPersistenceStatus(generationAtStart: UInt64) {
        let didFinish = lock.withLock { () -> Bool in
            guard generation == generationAtStart, phase == .saving else { return false }
            indexing = false
            reconciling = false
            updating = false
            phase = .ready
            status = "Saved index"
            activeOperationStartedAt = nil
            lastUpdated = Date()
            return true
        }
        if didFinish {
            publishStats()
        }
    }

    private func persistMetadataOverlay(
        replacingStore: ReplacingRecordStore,
        snapshot: SearchSnapshot,
        started: Date,
        priority: IndexMaintenancePriority
    ) throws {
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let replacements = replacingStore.metadataReplacementRecords
        guard !replacements.isEmpty else {
            removePersistedMetadataOverlay()
            return
        }

        let baseIdentity = try metadataOverlayBaseIdentity()
        guard
            baseIdentity.schemaVersion == snapshot.store.schemaVersion,
            baseIdentity.recordCount == snapshot.store.count
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        let overlay = PersistedMetadataOverlay(
            baseSnapshotSchemaVersion: baseIdentity.schemaVersion,
            baseRecordCount: baseIdentity.recordCount,
            baseSavedAt: baseIdentity.savedAt,
            replacements: replacements
        )
        let data = try overlay.encodedData()
        try data.write(to: metadataOverlayURL(), options: .atomic)
        invalidateStorageInsightsCache()

        MemoryTelemetry.log(
            "metadataOverlay.persist.finished",
            records: Self.countOnlyMetrics(for: snapshot.store),
            structures: snapshot.diagnostics,
            activeIndexJobs: currentActiveIndexJobCount()
        )
        DiagnosticLogger.shared.log(
            category: "index",
            event: "index.metadataOverlayPersistFinished",
            fields: [
                "recordCount": .publicInt(snapshot.count),
                "replacementCount": .publicInt(replacements.count),
                "durationSeconds": .publicDouble(Date().timeIntervalSince(started)),
                "pendingRefreshPathCount": .publicInt(lock.withLock { pendingRefreshPaths.count })
            ]
        )
        scheduleMetadataOverlayCheckpoint(
            snapshot,
            replacementCount: replacements.count,
            changedPathCount: 0,
            reason: "age",
            delay: metadataOverlayCheckpointDelay(),
            priority: priority
        )
    }

    private func metadataOverlayBaseIdentity() throws -> (schemaVersion: Int, recordCount: Int, savedAt: Date) {
        let manifestURL = snapshotURL.appendingPathComponent(SnapshotLayout.FileName.manifest, isDirectory: false)
        let manifest = try JSONDecoder().decode(CompactSnapshotManifest.self, from: Data(contentsOf: manifestURL))
        return (manifest.schemaVersion, manifest.recordCount, manifest.savedAt)
    }

    private func persistStructuralDeltaChanges(
        upserts: [FileRecord],
        tombstonedPaths: [String],
        previousSnapshot: SearchSnapshot
    ) -> StructuralDeltaPersistenceResult {
        guard !lock.withLock({ hasUnpersistedSnapshotChanges }) else {
            return .unavailable
        }
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            return .unavailable
        }

        let started = Date()
        do {
            let persistedBase = try metadataOverlayBaseIdentity()
            let baseIdentity = StructuralDeltaBaseIdentity(
                schemaVersion: persistedBase.schemaVersion,
                recordCount: persistedBase.recordCount,
                savedAt: persistedBase.savedAt
            )
            let activeStructuralDelta = lock.withLock { structuralDelta }
            if let activeStructuralDelta {
                guard activeStructuralDelta.baseIdentity.matches(baseIdentity) else {
                    return .failed
                }
            } else {
                let directlyUsesPersistedBase = previousSnapshot.store.kind == .mapped
                    || ((previousSnapshot.store as? ReplacingRecordStore)?.metadataBaseStoreKind == .mapped)
                guard
                    directlyUsesPersistedBase,
                    previousSnapshot.store.schemaVersion == baseIdentity.schemaVersion,
                    previousSnapshot.store.count == baseIdentity.recordCount
                else {
                    return .unavailable
                }
            }

            var changes: [StructuralDeltaChange] = []
            if activeStructuralDelta == nil,
               let replacingStore = previousSnapshot.store as? ReplacingRecordStore,
               replacingStore.metadataBaseStoreKind == .mapped {
                changes.append(contentsOf: replacingStore.metadataReplacementRecords.map {
                    StructuralDeltaChange.upsert($0)
                })
            }
            changes.append(contentsOf: tombstonedPaths.map {
                StructuralDeltaChange.tombstone(path: $0)
            })
            changes.append(contentsOf: upserts.map { StructuralDeltaChange.upsert($0) })

            let delta: StructuralDelta
            if var activeStructuralDelta {
                try activeStructuralDelta.apply(changes)
                try structuralDeltaStore.save(activeStructuralDelta)
                delta = activeStructuralDelta
            } else {
                delta = try structuralDeltaStore.append(
                    baseIdentity: baseIdentity,
                    changes: changes
                )
            }
            lock.withLock { structuralDelta = delta }
            removePersistedMetadataOverlay()
            invalidateStorageInsightsCache()
            DiagnosticLogger.shared.log(
                category: "index",
                event: "index.structuralDeltaPersistFinished",
                fields: [
                    "changeCount": .publicInt(delta.changeCount),
                    "batchUpsertCount": .publicInt(upserts.count),
                    "batchTombstoneCount": .publicInt(tombstonedPaths.count),
                    "durationSeconds": .publicDouble(Date().timeIntervalSince(started))
                ]
            )
            return .saved
        } catch {
            DiagnosticLogger.shared.log(
                level: .error,
                category: "index",
                event: "index.structuralDeltaPersistFailed",
                fields: [
                    "batchUpsertCount": .publicInt(upserts.count),
                    "batchTombstoneCount": .publicInt(tombstonedPaths.count),
                    "durationSeconds": .publicDouble(Date().timeIntervalSince(started)),
                    "error": .errorText(error.localizedDescription)
                ]
            )
            return .failed
        }
    }

    private func metadataOverlayURL() -> URL {
        snapshotURL.appendingPathComponent(SnapshotLayout.FileName.metadataOverlay, isDirectory: false)
    }

    private func removePersistedMetadataOverlay() {
        try? fileManager.removeItem(at: metadataOverlayURL())
    }

    private func loadPersistedMetadataOverlay(
        baseSnapshot: SearchSnapshot,
        manifest: CompactSnapshotManifest
    ) -> SearchSnapshot {
        let overlayURL = metadataOverlayURL()
        guard fileManager.fileExists(atPath: overlayURL.path) else {
            return baseSnapshot
        }

        do {
            let overlay = try PersistedMetadataOverlay.decode(from: Data(contentsOf: overlayURL, options: [.mappedIfSafe]))
            guard
                overlay.baseSnapshotSchemaVersion == manifest.schemaVersion,
                overlay.baseRecordCount == baseSnapshot.store.count,
                Self.metadataOverlayBaseDateMatches(overlay.baseSavedAt, manifest.savedAt)
            else {
                throw CocoaError(.fileReadCorruptFile)
            }

            var upserts: [String: FileRecord] = [:]
            upserts.reserveCapacity(overlay.replacements.count)
            for record in overlay.replacements {
                upserts[record.path] = record
            }

            if let updatedSnapshot = baseSnapshot.updatingMetadata(for: upserts) {
                DiagnosticLogger.shared.log(
                    category: "index",
                    event: "index.metadataOverlayLoadApplied",
                    fields: [
                        "replacementCount": .publicInt(upserts.count)
                    ]
                )
                return updatedSnapshot
            }

            let replacingSnapshot = try metadataOverlaySnapshotWithoutSearchStructures(
                baseSnapshot: baseSnapshot,
                replacements: Array(upserts.values)
            )
            DiagnosticLogger.shared.log(
                category: "index",
                event: "index.metadataOverlayLoadApplied",
                fields: [
                    "replacementCount": .publicInt(upserts.count),
                    "optimizedForSearch": .publicBool(false)
                ]
            )
            return replacingSnapshot
        } catch {
            discardPersistedMetadataOverlay(reason: "invalidBaseOrCorrupt", error: error)
            return baseSnapshot
        }
    }

    private func loadPersistedStructuralDelta(
        baseSnapshot: SearchSnapshot,
        manifest: CompactSnapshotManifest
    ) -> LoadedStructuralSnapshot {
        let baseIdentity = StructuralDeltaBaseIdentity(
            schemaVersion: manifest.schemaVersion,
            recordCount: manifest.recordCount,
            savedAt: manifest.savedAt
        )

        do {
            switch try structuralDeltaStore.load(expectedBaseIdentity: baseIdentity) {
            case .missing:
                return LoadedStructuralSnapshot(
                    snapshot: baseSnapshot,
                    delta: nil,
                    optimizedFallback: nil,
                    compositeSearchState: nil,
                    requiresFullReconciliation: false
                )
            case let .loaded(delta):
                guard !delta.isEmpty else {
                    return LoadedStructuralSnapshot(
                        snapshot: baseSnapshot,
                        delta: delta,
                        optimizedFallback: nil,
                        compositeSearchState: nil,
                        requiresFullReconciliation: false
                    )
                }

                var deletedRows = Set<Int>()
                deletedRows.reserveCapacity(delta.tombstones.count + delta.upserts.count)
                for path in delta.tombstones {
                    if let rowID = baseSnapshot.store.rowID(forPath: path) {
                        deletedRows.insert(rowID)
                    }
                }
                for record in delta.upserts {
                    if let rowID = baseSnapshot.store.rowID(forPath: record.path) {
                        deletedRows.insert(rowID)
                    }
                }

                let store = OverlayRecordStore(
                    base: baseSnapshot.store,
                    upserts: delta.upserts,
                    deletedRows: deletedRows
                )
                let snapshot = SearchSnapshot(
                    store: store,
                    buildsSearchStructures: false,
                    optimizedSortColumns: currentOptimizedSortColumns(),
                    buildsAdditionalSortOrders: false,
                    prefersDegradedSearch: true
                )
                DiagnosticLogger.shared.log(
                    category: "index",
                    event: "index.structuralDeltaLoadApplied",
                    fields: [
                        "changeCount": .publicInt(delta.changeCount),
                        "upsertCount": .publicInt(delta.upserts.count),
                        "tombstoneCount": .publicInt(delta.tombstones.count)
                    ]
                )
                let compositeState = makeCompositeSearchState(
                    logicalSnapshot: snapshot,
                    optimizedBase: baseSnapshot,
                    roots: manifest.roots,
                    previousState: nil,
                    changedUpserts: delta.upserts,
                    changedTombstonedPaths: delta.tombstones,
                    forceConsolidation: true
                )
                return LoadedStructuralSnapshot(
                    snapshot: snapshot,
                    delta: delta,
                    optimizedFallback: baseSnapshot.isOptimizedForSearch ? baseSnapshot : nil,
                    compositeSearchState: compositeState,
                    requiresFullReconciliation: false
                )
            case let .rejected(rejection):
                DiagnosticLogger.shared.log(
                    level: .warning,
                    category: "index",
                    event: "index.structuralDeltaDiscarded",
                    fields: [
                        "reason": .publicString(String(describing: rejection))
                    ]
                )
                try? structuralDeltaStore.clear()
                let requiresFullReconciliation: Bool
                switch rejection {
                case .corrupt, .unsupportedFormat:
                    requiresFullReconciliation = true
                case .baseIdentityMismatch:
                    requiresFullReconciliation = false
                }
                return LoadedStructuralSnapshot(
                    snapshot: baseSnapshot,
                    delta: nil,
                    optimizedFallback: nil,
                    compositeSearchState: nil,
                    requiresFullReconciliation: requiresFullReconciliation
                )
            }
        } catch {
            DiagnosticLogger.shared.log(
                level: .error,
                category: "index",
                event: "index.structuralDeltaLoadFailed",
                fields: [
                    "error": .errorText(error.localizedDescription)
                ]
            )
            return LoadedStructuralSnapshot(
                snapshot: baseSnapshot,
                delta: nil,
                optimizedFallback: nil,
                compositeSearchState: nil,
                requiresFullReconciliation: true
            )
        }
    }

    private static func metadataOverlayBaseDateMatches(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSinceReferenceDate - rhs.timeIntervalSinceReferenceDate) < 0.000_001
    }

    private func discardPersistedMetadataOverlay(reason: String, error: Error? = nil) {
        guard fileManager.fileExists(atPath: metadataOverlayURL().path) else { return }
        removePersistedMetadataOverlay()
        var fields: [String: DiagnosticLogFieldValue] = [
            "reason": .publicString(reason)
        ]
        if let error {
            fields["error"] = .errorText(error.localizedDescription)
        }
        DiagnosticLogger.shared.log(
            level: error == nil ? .info : .error,
            category: "index",
            event: "index.metadataOverlayDiscarded",
            fields: fields
        )
    }

    private func metadataOverlaySnapshotWithoutSearchStructures(
        baseSnapshot: SearchSnapshot,
        replacements: [FileRecord]
    ) throws -> SearchSnapshot {
        var rowReplacements: [Int: FileRecord] = [:]
        rowReplacements.reserveCapacity(replacements.count)

        for replacement in replacements {
            guard
                let rowID = baseSnapshot.store.rowID(forPath: replacement.path),
                Self.metadataSearchKeysMatch(store: baseSnapshot.store, rowID: rowID, replacement: replacement)
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
            rowReplacements[rowID] = replacement
        }

        return SearchSnapshot(
            store: ReplacingRecordStore(base: baseSnapshot.store, replacements: rowReplacements),
            buildsSearchStructures: false,
            prefersDegradedSearch: true
        )
    }

    private static func metadataSearchKeysMatch(
        store: RecordStore,
        rowID: Int,
        replacement: FileRecord
    ) -> Bool {
        store.path(at: rowID) == replacement.path
            && store.name(at: rowID) == replacement.name
            && store.directoryPath(at: rowID) == replacement.directoryPath
            && store.fileExtension(at: rowID) == replacement.fileExtension
            && store.normalizedName(at: rowID) == replacement.normalizedName
            && store.normalizedPath(at: rowID) == replacement.normalizedPath
    }

    private static func storedRecord(
        _ store: RecordStore,
        at rowID: Int,
        matches record: FileRecord
    ) -> Bool {
        store.recordID(at: rowID) == record.id
            && store.sizeBytes(at: rowID) == record.sizeBytes
            && store.modifiedTime(at: rowID) == record.modifiedTime
            && store.createdTime(at: rowID) == record.createdTime
            && store.isDirectory(at: rowID) == record.isDirectory
            && store.isHidden(at: rowID) == record.isHidden
            && store.volumeName(at: rowID) == record.volumeName
    }

    private func persistMappedSnapshot(
        roots: [String],
        exclusionPatterns: [String],
        store: RecordStore,
        preparePackageBeforeInstall: (MappedRecordStore, URL) throws -> Void = { _, _ in }
    ) throws -> MappedRecordStore {
        cleanupStaleTemporaryFiles()
        let temporaryURL = SnapshotLayout.temporaryPackageURL(in: supportDirectory)
        defer {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        try MappedRecordStore.writePackage(
            recordSource: RecordPackageRecordSource(
                estimatedRecordCount: store.storedResultCount ?? store.count,
                enumerateRecords: store.forEachResultRecord
            ),
            roots: roots,
            exclusionPatterns: exclusionPatterns,
            packageURL: temporaryURL,
            fileManager: fileManager
        )

        let mappedStore = try MappedRecordStore(packageURL: temporaryURL, schemaVersion: SnapshotLayout.schemaVersion)
        try preparePackageBeforeInstall(mappedStore, temporaryURL)

        if fileManager.fileExists(atPath: snapshotURL.path) {
            try fileManager.removeItem(at: snapshotURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: snapshotURL)
        removePersistedMetadataOverlay()
        try? structuralDeltaStore.clear()
        lock.withLock {
            structuralDelta = nil
            clearStructuralDeltaCompactionWithoutLock()
            clearSnapshotDurabilityPendingWithoutLock()
        }
        removeScanCheckpoint()
        cleanupObsoleteIndexFiles()
        invalidateStorageInsightsCache()
        return mappedStore
    }

    private func persistSearchStructures(for snapshot: SearchSnapshot, packageURL: URL) throws {
        let modifiedOrderURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.modifiedOrder, isDirectory: false)
        if snapshot.hasModifiedSortOrder {
            try CompactSearchStructureFiles.writeModifiedOrder(
                snapshot.modifiedDescending,
                to: modifiedOrderURL
            )
        } else {
            try Data().write(to: modifiedOrderURL, options: .atomic)
        }

        let visibleModifiedOrderURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.visibleModifiedOrder, isDirectory: false)
        if snapshot.hasModifiedSortOrder {
            try CompactSearchStructureFiles.writeModifiedOrder(
                snapshot.visibleModifiedDescending,
                to: visibleModifiedOrderURL
            )
        } else {
            try Data().write(to: visibleModifiedOrderURL, options: .atomic)
        }

        let enabledSortColumns = lock.withLock { optimizedSortColumns }
        for column in SortColumn.optimizedIndexColumns where column != .modified {
            guard let fileName = Self.sortOrderFileName(for: column) else { continue }
            let sortOrderURL = packageURL.appendingPathComponent(fileName, isDirectory: false)
            if
                enabledSortColumns.contains(column),
                let order = snapshot.persistedSortOrderAscending(for: column),
                order.count == snapshot.resultCount
            {
                try CompactSearchStructureFiles.writeModifiedOrder(order, to: sortOrderURL)
            } else {
                try Data().write(to: sortOrderURL, options: .atomic)
            }
        }

        let namePostingsURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.namePostings, isDirectory: false)
        if let nameGramIndex = snapshot.nameGramIndex {
            try nameGramIndex.write(to: namePostingsURL)
        } else {
            try Data().write(to: namePostingsURL, options: .atomic)
        }

        let componentPostingsURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.componentPostings, isDirectory: false)
        let componentSupplementURL = packageURL.appendingPathComponent(
            SnapshotLayout.FileName.componentSupplementPostings,
            isDirectory: false
        )
        switch snapshot.componentGramIndex {
        case .combined(let componentGramIndex):
            // Preserve old combined indexes until a normal optimization rebuilds
            // them. Absence of the supplement file is the legacy-format marker.
            try componentGramIndex.write(to: componentPostingsURL)
            if fileManager.fileExists(atPath: componentSupplementURL.path) {
                try fileManager.removeItem(at: componentSupplementURL)
            }
        case .shared:
            try Data().write(to: componentPostingsURL, options: .atomic)
            // Presence of this empty marker distinguishes the all-row union format
            // from an incomplete legacy snapshot. Older readers ignore the marker
            // and already alias the empty component file to names.
            try Data().write(to: componentSupplementURL, options: .atomic)
        case nil:
            try Data().write(to: componentPostingsURL, options: .atomic)
            if fileManager.fileExists(atPath: componentSupplementURL.path) {
                try fileManager.removeItem(at: componentSupplementURL)
            }
        }

        let pathPostingsURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.pathPostings, isDirectory: false)
        if let gramIndex = snapshot.gramIndex {
            try gramIndex.write(to: pathPostingsURL)
        } else {
            try Data().write(to: pathPostingsURL, options: .atomic)
        }
    }

    private func persistScanCheckpoint(
        _ progress: ScanCheckpointProgress,
        roots: [String],
        exclusionPatterns: [String],
        generation currentGeneration: UInt64,
        requiresActiveScan: Bool = true
    ) {
        guard shouldPersistScanCheckpoint(generation: currentGeneration, requiresActiveScan: requiresActiveScan) else { return }

        checkpointPersistenceLock.withLock {
            guard shouldPersistScanCheckpoint(generation: currentGeneration, requiresActiveScan: requiresActiveScan) else { return }

            let savedAt = Date()
            let temporaryURL = SnapshotLayout.temporaryCheckpointPackageURL(in: supportDirectory)
            defer {
                if fileManager.fileExists(atPath: temporaryURL.path) {
                    try? fileManager.removeItem(at: temporaryURL)
                }
            }

            do {
                try MappedRecordStore.writePackage(
                    records: progress.store.allRecords(),
                    roots: roots,
                    exclusionPatterns: exclusionPatterns,
                    packageURL: temporaryURL,
                    savedAt: savedAt,
                    fileManager: fileManager
                )
                guard shouldPersistScanCheckpoint(generation: currentGeneration, requiresActiveScan: requiresActiveScan) else { return }
                let mappedStore = try MappedRecordStore(packageURL: temporaryURL, schemaVersion: SnapshotLayout.schemaVersion)
                let snapshot = SearchSnapshot(store: mappedStore, buildsSearchStructures: false)
                try persistSearchStructures(for: snapshot, packageURL: temporaryURL)
                guard shouldPersistScanCheckpoint(generation: currentGeneration, requiresActiveScan: requiresActiveScan) else { return }

                let state = ScanCheckpointState(
                    schemaVersion: SnapshotLayout.schemaVersion,
                    savedAt: savedAt,
                    operationStartedAt: progress.operationStartedAt,
                    roots: roots,
                    exclusionPatterns: exclusionPatterns,
                    pendingDirectories: progress.pendingDirectories,
                    activeDirectories: progress.activeDirectories,
                    completedDirectories: progress.completedDirectories,
                    discoveredCount: progress.visited,
                    recordCount: mappedStore.count
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(state).write(
                    to: temporaryURL.appendingPathComponent(SnapshotLayout.FileName.scanState, isDirectory: false),
                    options: .atomic
                )

                if fileManager.fileExists(atPath: checkpointURL.path) {
                    try fileManager.removeItem(at: checkpointURL)
                }
                try fileManager.moveItem(at: temporaryURL, to: checkpointURL)
                cleanupStaleTemporaryFiles()

                let didUpdate = lock.withLock { () -> Bool in
                    guard generation == currentGeneration else { return false }
                    lastCheckpointAt = savedAt
                    lastUpdated = Date()
                    return true
                }
                if didUpdate {
                    publishStats()
                }
                MemoryTelemetry.log(
                    "checkpoint.persisted",
                    activeIndexJobs: currentActiveIndexJobCount()
                )
                DiagnosticLogger.shared.log(
                    category: "index",
                    event: "index.checkpointPersisted",
                    fields: [
                        "rootCount": .publicInt(roots.count),
                        "recordCount": .publicInt(mappedStore.count),
                        "pendingDirectoryCount": .publicInt(progress.pendingDirectories.count),
                        "activeDirectoryCount": .publicInt(progress.activeDirectories.count),
                        "completedDirectoryCount": .publicInt(progress.completedDirectories.count)
                    ]
                )
            } catch {
                MemoryTelemetry.log("checkpoint.persist.failed", activeIndexJobs: currentActiveIndexJobCount())
                DiagnosticLogger.shared.log(
                    level: .error,
                    category: "index",
                    event: "index.checkpointPersistFailed",
                    fields: [
                        "rootCount": .publicInt(roots.count),
                        "recordCount": .publicInt(progress.store.count),
                        "error": .errorText(error.localizedDescription)
                    ]
                )
                try? fileManager.removeItem(at: temporaryURL)
            }
        }
    }

    private func shouldPersistScanCheckpoint(generation currentGeneration: UInt64, requiresActiveScan: Bool) -> Bool {
        lock.withLock {
            generation == currentGeneration && (!requiresActiveScan || (indexing && phase == .scanning))
        }
    }

    private func persistScanCheckpointAsync(
        _ progress: ScanCheckpointProgress,
        roots: [String],
        exclusionPatterns: [String],
        generation currentGeneration: UInt64
    ) {
        var shouldEnqueue = false
        checkpointPersistenceLock.withLock {
            if !checkpointWriteInFlight {
                checkpointWriteInFlight = true
                shouldEnqueue = true
            }
        }

        guard shouldEnqueue else { return }

        checkpointQueue.async { [weak self] in
            guard let self else { return }
            self.persistScanCheckpoint(
                progress,
                roots: roots,
                exclusionPatterns: exclusionPatterns,
                generation: currentGeneration
            )
            self.checkpointPersistenceLock.withLock {
                self.checkpointWriteInFlight = false
            }
        }
    }

    private func loadResumableScanCheckpoint(roots: [String], exclusionPatterns: [String]) -> LoadedScanCheckpoint? {
        guard let state = matchingScanCheckpointState(
            roots: roots,
            exclusionPatterns: exclusionPatterns,
            removesInvalidCheckpoint: true
        ) else {
            return nil
        }

        do {
            let store = try MappedRecordStore(packageURL: checkpointURL, schemaVersion: SnapshotLayout.schemaVersion)
            guard store.count == state.recordCount else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let searchStructures = loadPersistedSearchStructures(packageURL: checkpointURL, store: store) ?? .empty
            return LoadedScanCheckpoint(state: state, store: store, searchStructures: searchStructures)
        } catch {
            removeScanCheckpoint()
            recordSnapshotLoadFailure(corruptSnapshotRemoved: true)
            MemoryTelemetry.log("checkpoint.load.failed", activeIndexJobs: currentActiveIndexJobCount())
            return nil
        }
    }

    private func matchingScanCheckpointState(
        roots: [String],
        exclusionPatterns: [String],
        removesInvalidCheckpoint: Bool
    ) -> ScanCheckpointState? {
        guard fileManager.fileExists(atPath: checkpointURL.path) else {
            return nil
        }

        do {
            let stateURL = checkpointURL.appendingPathComponent(SnapshotLayout.FileName.scanState, isDirectory: false)
            let state = try JSONDecoder().decode(ScanCheckpointState.self, from: Data(contentsOf: stateURL))
            guard
                state.schemaVersion == SnapshotLayout.schemaVersion,
                state.roots == roots,
                state.exclusionPatterns == exclusionPatterns,
                state.recordCount >= 0,
                state.discoveredCount >= 0
            else {
                throw CocoaError(.fileReadCorruptFile)
            }

            if let finalSavedAt = finalSnapshotSavedAt(), finalSavedAt >= state.savedAt {
                if removesInvalidCheckpoint {
                    removeScanCheckpoint()
                }
                return nil
            }

            return state
        } catch {
            if removesInvalidCheckpoint {
                removeScanCheckpoint()
            }
            return nil
        }
    }

    private func finalSnapshotSavedAt() -> Date? {
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            return nil
        }

        let manifestURL = snapshotURL.appendingPathComponent(SnapshotLayout.FileName.manifest, isDirectory: false)
        guard
            let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(CompactSnapshotManifest.self, from: data),
            manifest.schemaVersion == SnapshotLayout.schemaVersion
        else {
            return nil
        }
        return manifest.savedAt
    }

    private func removeSupersededScanCheckpoint(finalSavedAt: Date) {
        guard fileManager.fileExists(atPath: checkpointURL.path) else {
            return
        }

        let stateURL = checkpointURL.appendingPathComponent(SnapshotLayout.FileName.scanState, isDirectory: false)
        guard
            let data = try? Data(contentsOf: stateURL),
            let state = try? JSONDecoder().decode(ScanCheckpointState.self, from: data)
        else {
            removeScanCheckpoint()
            return
        }

        if state.schemaVersion != SnapshotLayout.schemaVersion || finalSavedAt >= state.savedAt {
            removeScanCheckpoint()
        }
    }

    private func applyLoadedScanCheckpoint(_ checkpoint: LoadedScanCheckpoint, generation currentGeneration: UInt64) {
        let snapshot = shouldPublishSearchableSnapshotsDuringScan()
            ? SearchSnapshot(
                store: checkpoint.store,
                persistedStructures: checkpoint.searchStructures,
                optimizedSortColumns: currentOptimizedSortColumns()
            )
            : nil
        let didApply = lock.withLock { () -> Bool in
            guard generation == currentGeneration else { return false }
            if let snapshot {
                searchSnapshot = snapshot
                searchSnapshotRevision &+= 1
                searchableCount = snapshot.resultCount
                optimizedCount = snapshot.isOptimizedForSearch ? snapshot.resultCount : 0
            } else {
                searchableCount = searchSnapshot.resultCount
                optimizedCount = searchSnapshot.isOptimizedForSearch ? searchSnapshot.resultCount : 0
            }
            indexing = true
            reconciling = false
            updating = false
            phase = .scanning
            discoveredCount = checkpoint.state.discoveredCount
            status = "Indexing from \(checkpoint.state.recordCount.formatted()) checkpoint records"
            activeOperationStartedAt = checkpoint.state.operationStartedAt
            lastCheckpointAt = checkpoint.state.savedAt
            resumedFromCheckpoint = true
            lastUpdated = Date()
            return true
        }

        if didApply {
            publishStats()
            MemoryTelemetry.log(
                "checkpoint.load.applied",
                activeIndexJobs: currentActiveIndexJobCount()
            )
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
            let searchStructures = loadPersistedSearchStructures(packageURL: snapshotURL, store: store) ?? .empty
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
        let visibleModifiedDescending = store.storedVisibleCount.flatMap { visibleCount in
            CompactSearchStructureFiles.loadModifiedOrder(
                from: packageURL.appendingPathComponent(SnapshotLayout.FileName.visibleModifiedOrder, isDirectory: false),
                expectedCount: visibleCount,
                rowIDUpperBound: store.count,
                fileManager: fileManager
            )
        }
        let nameGramIndex = try? MappedIntPostingIndex.load(
            from: packageURL.appendingPathComponent(SnapshotLayout.FileName.namePostings, isDirectory: false),
            fileManager: fileManager
        )
        let pathGramIndex = try? MappedIntPostingIndex.load(
            from: packageURL.appendingPathComponent(SnapshotLayout.FileName.pathPostings, isDirectory: false),
            fileManager: fileManager
        )
        let legacyComponentGramIndex = try? MappedIntPostingIndex.load(
            from: packageURL.appendingPathComponent(SnapshotLayout.FileName.componentPostings, isDirectory: false),
            fileManager: fileManager
        )
        let componentSupplementURL = packageURL.appendingPathComponent(
            SnapshotLayout.FileName.componentSupplementPostings,
            isDirectory: false
        )
        let componentGramIndex: ComponentGramPostingIndex?
        if fileManager.fileExists(atPath: componentSupplementURL.path) {
            do {
                let virtualRows = try MappedIntPostingIndex.load(
                    from: componentSupplementURL,
                    fileManager: fileManager
                )
                if virtualRows != nil {
                    // A short-lived split format wrote result and virtual rows to
                    // separate files. Keep the valid sort/path structures and
                    // rebuild only the shared name/component union.
                    componentGramIndex = nil
                } else {
                    guard let nameGramIndex = nameGramIndex ?? nil else { return nil }
                    componentGramIndex = .shared(nameGramIndex)
                }
            } catch {
                // Treat a corrupt supplement as an incomplete optimization. The
                // caller will retain the record snapshot and rebuild its indexes.
                return nil
            }
        } else if let legacyComponentGramIndex = legacyComponentGramIndex ?? nil {
            componentGramIndex = .combined(legacyComponentGramIndex)
        } else {
            componentGramIndex = nil
        }
        let enabledSortColumns = lock.withLock { optimizedSortColumns }
        var sortOrdersAscending: [SortColumn: [Int]] = [:]
        for column in enabledSortColumns where column != .modified {
            guard let fileName = Self.sortOrderFileName(for: column) else { continue }
            guard let order = CompactSearchStructureFiles.loadModifiedOrder(
                from: packageURL.appendingPathComponent(fileName, isDirectory: false),
                expectedCount: store.storedResultCount ?? store.count,
                rowIDUpperBound: store.count,
                fileManager: fileManager
            ) else {
                continue
            }
            sortOrdersAscending[column] = order
        }
        return PersistedSearchStructures(
            modifiedDescending: modifiedDescending,
            visibleModifiedDescending: visibleModifiedDescending,
            sortOrdersAscending: sortOrdersAscending,
            nameGramIndex: nameGramIndex ?? nil,
            componentGramIndex: componentGramIndex,
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

    private static func shouldBuildPathGramIndex(records: [FileRecord]) -> Bool {
        guard records.count <= pathGramRecordLimit else { return false }
        let metrics = metrics(for: records)
        return shouldBuildPathGramIndex(recordCount: metrics.recordCount, totalPathBytes: metrics.totalPathBytes)
    }

    private static func shouldBuildPathGramIndex(store: RecordStore) -> Bool {
        guard store.count <= pathGramRecordLimit else { return false }
        if store.mappedByteSize > pathGramTotalPathByteLimit {
            return false
        }
        let metrics = metrics(for: store)
        return shouldBuildPathGramIndex(recordCount: metrics.recordCount, totalPathBytes: metrics.totalPathBytes)
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

    private static func countOnlyMetrics(for store: RecordStore) -> RecordCollectionMetrics {
        RecordCollectionMetrics(recordCount: store.count, totalPathBytes: 0, maxPathBytes: 0)
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
        updateUsageMetricsDeferred { metrics in
            metrics.recordActiveJobHighWaterMark(activeJobs)
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

    private func recordScanFrontierMetrics(_ metrics: ScanFrontierMetrics, generation currentGeneration: UInt64) {
        lock.withLock {
            guard generation == currentGeneration else { return }
            lastScanFrontierMetrics = metrics
        }
    }

    func currentDiagnostics() -> FileIndexDiagnostics {
        lock.withLock {
            currentDiagnosticsWithoutLock()
        }
    }

    func hasPendingDurabilityForTesting() -> Bool {
        lock.withLock {
            hasUnpersistedSnapshotChanges || !pendingDurabilityCompletions.isEmpty
        }
    }

    func markSnapshotDurabilityPendingForTesting() {
        markSnapshotDurabilityPending(schedulesRetry: false)
    }

    func durabilityRevisionsForTesting() -> (snapshot: UInt64, unpersisted: UInt64?) {
        lock.withLock {
            (searchSnapshotRevision, unpersistedSnapshotRevision)
        }
    }

    func structuralDeltaCompactionScheduleForTesting() -> (
        revision: UInt64,
        scheduledAt: Date,
        writerConflictWarningDeadline: Date
    )? {
        lock.withLock {
            guard
                let scheduledAt = structuralDeltaCompactionScheduledAt,
                let writerConflictWarningDeadline = structuralDeltaCompactionWriterConflictWarningDeadline
            else {
                return nil
            }
            return (
                structuralDeltaCompactionRevision,
                scheduledAt,
                writerConflictWarningDeadline
            )
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
            pathGramCoveredRowCount: searchSnapshot.diagnostics.pathGramCoveredRowCount,
            pathGramTotalRowCount: searchSnapshot.diagnostics.pathGramTotalRowCount,
            nameGramKeyCount: searchSnapshot.diagnostics.nameGramKeyCount,
            nameGramPostingCount: searchSnapshot.diagnostics.nameGramPostingCount,
            componentGramKeyCount: searchSnapshot.diagnostics.componentGramKeyCount,
            componentGramPostingCount: searchSnapshot.diagnostics.componentGramPostingCount,
            extensionKeyCount: searchSnapshot.diagnostics.extensionKeyCount,
            extensionPostingCount: searchSnapshot.diagnostics.extensionPostingCount,
            compositeSearchSegmentCount: compositeSearchState?.segmentCount ?? 0,
            compositeMaskedRowCount: compositeSearchState?.maskedRowCount ?? 0,
            pendingRefreshPathCount: pendingRefreshPaths.count,
            pendingBackgroundRefreshPathCount: pendingRefreshPaths.values.filter { $0.priority == .background }.count,
            completedRefreshBatches: completedRefreshBatches,
            completedSnapshotRebuilds: completedSnapshotRebuilds,
            activeIndexJobs: activeIndexJobs,
            schemaVersion: searchSnapshot.store.schemaVersion,
            resultCount: searchSnapshot.resultCount,
            virtualRowCount: searchSnapshot.virtualRowCount,
            fallbackScanCount: fallbackScanCount,
            scannedRowCount: scannedRowCount,
            pathMaterializationCount: pathMaterializationCount,
            lastCheckpointAt: lastCheckpointAt,
            resumedFromCheckpoint: resumedFromCheckpoint,
            scanFrontierMetrics: lastScanFrontierMetrics
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
            canClearCachedIndex: activeIndexJobs == 0 && !indexing && snapshotLoadState != .loading,
            maintenance: currentMaintenanceDiagnosticsWithoutLock()
        )
    }

    private func currentMaintenanceDiagnosticsWithoutLock() -> IndexMaintenanceLiveDiagnostics {
        IndexMaintenanceLiveDiagnostics(
            pendingRefreshPathCount: pendingRefreshPaths.count,
            pendingBackgroundRefreshPathCount: pendingRefreshPaths.values.filter { $0.priority == .background }.count,
            pendingReconciliationScopeCount: pendingReconciliationIncludesAllRoots ? roots.count : pendingReconciliationPaths.count,
            isFullReconciliationPending: pendingReconciliationIncludesAllRoots,
            lastOperation: lastMaintenanceOperation,
            lastBackgroundSlice: lastBackgroundMaintenanceSlice,
            deferredOptimizationReason: deferredOptimizationReason,
            deferredOptimizationDelay: deferredOptimizationDelay,
            deferredCheckpointReason: deferredCheckpointReason,
            deferredCheckpointDelay: deferredCheckpointDelay
        )
    }

    func replaceRecordsForTesting(
        _ records: [FileRecord],
        roots rootURLs: [URL] = [],
        buildsSearchStructures: Bool = true,
        phase: IndexPhase = .ready,
        status: String? = nil,
        prefersDegradedSearch: Bool = false
    ) {
        let recordsByPath = Dictionary(uniqueKeysWithValues: records.map { ($0.path, $0) })
        let canonicalRoots = canonicalizedRoots(rootURLs).map(\.path)
        indexQueue.sync {
            let snapshot = SearchSnapshot(
                records: records,
                roots: canonicalRoots,
                buildsSearchStructures: buildsSearchStructures,
                optimizedSortColumns: currentOptimizedSortColumns(),
                prefersDegradedSearch: prefersDegradedSearch
            )
            lock.withLock {
                clearOptimizedSearchFallbackWithoutLock()
                roots = canonicalRoots
                self.recordsByPath = recordsByPath
                searchSnapshot = snapshot
                searchSnapshotRevision &+= 1
                indexing = phase == .scanning || phase == .optimizing || phase == .saving
                reconciling = false
                updating = false
                activityPresentation = .foreground
                clearActiveReconciliationWithoutLock()
                self.phase = phase
                discoveredCount = records.count
                searchableCount = snapshot.resultCount
                optimizedCount = buildsSearchStructures ? snapshot.resultCount : 0
                self.status = status ?? "Indexed \(records.count.formatted()) test files"
                lastUpdated = Date()
                activeOperationStartedAt = indexing ? Date() : nil
                lastCheckpointAt = nil
                resumedFromCheckpoint = false
                if phase == .ready {
                    completedSnapshotRebuilds &+= 1
                }
            }
            publishStats()
        }
    }

    func applyStructuralOverlayForTesting(
        upserts: [FileRecord],
        tombstonedPaths: [String]
    ) {
        indexQueue.sync {
            let prior = lock.withLock {
                (
                    snapshot: searchSnapshot,
                    composite: compositeSearchState,
                    optimizedFallback: optimizedSearchFallbackSnapshot,
                    roots: roots
                )
            }
            var deletedRows = Set<Int>()
            for path in tombstonedPaths {
                if let rowID = prior.snapshot.store.rowID(forPath: path) {
                    deletedRows.insert(rowID)
                }
            }
            for record in upserts {
                if let rowID = prior.snapshot.store.rowID(forPath: record.path) {
                    deletedRows.insert(rowID)
                }
            }

            let store = OverlayRecordStore(
                base: prior.snapshot.store,
                upserts: upserts,
                deletedRows: deletedRows
            )
            let snapshot = SearchSnapshot(
                store: store,
                buildsSearchStructures: false,
                buildsPathGramIndex: false,
                optimizedSortColumns: currentOptimizedSortColumns(),
                buildsAdditionalSortOrders: false,
                prefersDegradedSearch: true
            )
            let composite = makeCompositeSearchState(
                logicalSnapshot: snapshot,
                optimizedBase: prior.composite?.base.sourceSnapshot
                    ?? prior.optimizedFallback
                    ?? (prior.snapshot.isOptimizedForSearch ? prior.snapshot : nil),
                roots: prior.roots,
                previousState: prior.composite,
                changedUpserts: upserts,
                changedTombstonedPaths: tombstonedPaths
            )
            lock.withLock {
                searchSnapshot = snapshot
                compositeSearchState = composite
                searchSnapshotRevision &+= 1
                discoveredCount = snapshot.resultCount
                searchableCount = snapshot.resultCount
                optimizedCount = composite == nil ? 0 : snapshot.resultCount
                status = "Applied \((upserts.count + tombstonedPaths.count).formatted()) test changes"
                lastUpdated = Date()
            }
        }
    }

    func compositeSearchDiagnosticsForTesting() -> (
        segmentCount: Int,
        maskedRowCount: Int
    )? {
        lock.withLock {
            compositeSearchState.map {
                ($0.segmentCount, $0.maskedRowCount)
            }
        }
    }

    func hasOptimizedSortOrderForTesting(_ column: SortColumn) -> Bool {
        lock.withLock {
            searchSnapshot.hasOptimizedSortOrder(
                for: column,
                optimizedSortColumns: optimizedSortColumns
            )
        }
    }

    func setExclusionEvaluationModeForTesting(_ mode: ExclusionEvaluationMode) {
        lock.withLock {
            exclusionEvaluationMode = mode
        }
    }

    func setScanFrontierBatchingForTesting(mode: ScanFrontierMode, batchSize: Int = 1) {
        lock.withLock {
            scanFrontierMode = mode
            scanFrontierBatchSize = min(max(batchSize, 1), 1_024)
        }
    }

    func setDeferredOptimizationRecordThresholdForTesting(_ threshold: Int) {
        lock.withLock {
            deferredOptimizationRecordThreshold = max(threshold, 0)
        }
    }

    func setExactEmptyQuerySortLimitForTesting(_ limit: Int?) {
        lock.withLock {
            exactEmptyQuerySortLimitOverride = limit.map { max($0, 0) }
        }
    }

    func removePathGramAccelerationForTesting() {
        indexQueue.sync {
            lock.withLock {
                searchSnapshot = searchSnapshot.removingPathGramAcceleration()
                searchSnapshotRevision &+= 1
                lastUpdated = Date()
            }
            publishStats()
        }
    }

    func addPathGramShardForTesting(range rawRange: Range<Int>) {
        indexQueue.sync {
            let state = lock.withLock {
                (snapshot: searchSnapshot, revision: searchSnapshotRevision)
            }
            let lowerBound = max(0, rawRange.lowerBound)
            let upperBound = min(state.snapshot.count, rawRange.upperBound)
            guard lowerBound < upperBound else { return }

            let range = lowerBound..<upperBound
            let shardMap = SearchSnapshot.makePathGramPostingMap(store: state.snapshot.store, range: range)
            let shardIndex = try? MappedIntPostingIndex.build(
                from: shardMap,
                temporaryName: "att-path-postings-test-shard"
            )
            let shard = SearchSnapshot.PathGramShard(
                snapshotRevision: state.revision,
                schemaVersion: state.snapshot.store.schemaVersion,
                rowCount: state.snapshot.count,
                range: range,
                completedAt: Date(),
                index: shardIndex
            )

            lock.withLock {
                guard searchSnapshotRevision == state.revision, searchSnapshot.store === state.snapshot.store else { return }
                let snapshotWithoutCompleteSidecar = searchSnapshot.gramIndex == nil
                    ? searchSnapshot
                    : searchSnapshot.removingPathGramAcceleration()
                searchSnapshot = snapshotWithoutCompleteSidecar.addingPathGramShard(
                    shard,
                    expectedRowCount: state.snapshot.count
                )
                searchSnapshotRevision &+= 1
                lastUpdated = Date()
            }
            publishStats()
        }
    }

    func completePathGramIndexForTesting() {
        indexQueue.sync {
            let state = lock.withLock {
                (snapshot: searchSnapshot, revision: searchSnapshotRevision)
            }
            guard FileIndex.shouldBuildPathGramIndex(store: state.snapshot.store) else { return }
            let pathGramIndex = SearchSnapshot.makePathGramIndex(
                store: state.snapshot.store,
                range: 0..<state.snapshot.count,
                temporaryName: "att-path-postings-test-complete"
            )

            lock.withLock {
                guard searchSnapshotRevision == state.revision, searchSnapshot.store === state.snapshot.store else { return }
                searchSnapshot = searchSnapshot.addingCompletePathGramIndex(pathGramIndex)
                searchSnapshotRevision &+= 1
                lastUpdated = Date()
            }
            publishStats()
        }
    }

    func persistSnapshotForTesting() {
        _ = indexQueue.sync {
            persistSnapshot(schedulesPathGramBuild: false)
        }
    }

    func scheduleAutomaticPersistForTesting(delay: TimeInterval = 0) {
        schedulePersist(delay: delay)
    }

    func pendingDirectoryRefreshStateForTesting(
        path rawPath: String
    ) -> (
        recordCount: Int,
        requiresFollowUp: Bool,
        incrementalPublishBatchCount: Int,
        incrementallyPublishedChangeCount: Int,
        unpublishedRecordCount: Int,
        pendingURLCount: Int,
        activeEnumerationEntryCount: Int?,
        retryAttempt: Int,
        recursivelyScansDirectory: Bool,
        followUpRecursivelyScansDirectory: Bool
    )? {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        return lock.withLock {
            guard
                let work = pendingRefreshPaths[path],
                let progress = work.directoryScanProgress
            else {
                return nil
            }
            let unpublishedRecordCount = progress.finalization.map {
                max($0.unpublishedRecords.count - $0.upsertsVisited, 0)
            } ?? progress.unpublishedRecords.count
            return (
                progress.scannedRecordCount,
                work.requiresDirectoryRescanAfterProgress,
                progress.incrementalPublishBatchCount,
                progress.incrementallyPublishedChangeCount,
                unpublishedRecordCount,
                progress.pendingURLs.count,
                progress.activeEnumeration?.readEntryCount,
                work.retryAttempt,
                work.recursivelyScansDirectory,
                work.followUpRecursivelyScansDirectory
            )
        }
    }

    func pendingDirectoryFinalizationStateForTesting(
        path rawPath: String
    ) -> (
        phase: String,
        traversalWorkCount: Int,
        seenBaselineRowCount: Int,
        baselineRowsVisited: Int,
        matchingBaselineRowsVisited: Int,
        upsertsVisited: Int,
        preparedUpsertCount: Int,
        materializedDeletionPathCount: Int
    )? {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        return lock.withLock {
            guard
                let progress = pendingRefreshPaths[path]?.directoryScanProgress,
                let finalization = progress.finalization
            else {
                return nil
            }
            return (
                finalization.phase.rawValue,
                progress.traversalWorkCount,
                progress.seenBaselineRows.setBitCount,
                finalization.baselineRowsVisited,
                finalization.matchingBaselineRowsVisited,
                finalization.upsertsVisited,
                finalization.preparedUpsertPaths.count,
                finalization.materializedDeletionPathCount
            )
        }
    }

    func pendingRefreshRetryStateForTesting(
        path rawPath: String
    ) -> (attempt: Int, eligibleAt: Date?)? {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        return lock.withLock {
            guard let work = pendingRefreshPaths[path] else { return nil }
            return (work.retryAttempt, work.eligibleAt)
        }
    }

    func pendingDirectoryTraversalPathsForTesting(
        path rawPath: String
    ) -> (pending: [String], deferredRetries: [String])? {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        return lock.withLock {
            guard
                let work = pendingRefreshPaths[path],
                let progress = work.directoryScanProgress
            else {
                return nil
            }
            return (
                progress.pendingURLs.map(\.path),
                progress.deferredRetryURLs.map(\.path)
            )
        }
    }

    static func backgroundRefreshRetryDelayForTesting(
        baseDelay: TimeInterval,
        priorFailureCount: Int
    ) -> TimeInterval {
        backgroundRefreshRetryDelay(
            baseDelay: baseDelay,
            priorFailureCount: priorFailureCount
        )
    }

    func pendingRefreshPathsForTesting() -> Set<String> {
        lock.withLock { Set(pendingRefreshPaths.keys) }
    }

    func promotePendingRefreshForTesting(path rawPath: String) {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        lock.withLock {
            guard var work = pendingRefreshPaths[path] else { return }
            work.promote()
            pendingRefreshPaths[path] = work
        }
        scheduleUpdateDrainIfNeeded(delay: .milliseconds(0))
    }

    func resumePendingRefreshForTesting(path rawPath: String) {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        lock.withLock {
            guard var work = pendingRefreshPaths[path] else { return }
            work.eligibleAt = nil
            pendingRefreshPaths[path] = work
        }
        scheduleUpdateDrainIfNeeded(delay: .milliseconds(0))
    }

    func failNextDirectoryUpdateEnumerationsForTesting(path rawPath: String, count: Int = 1) {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        indexQueue.sync {
            directoryUpdateEnumerationFailuresForTesting[path] = max(count, 0)
        }
    }

    func failNextFileSystemLookupsForTesting(
        path rawPath: String,
        error: Int32 = EIO,
        count: Int = 1
    ) {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        indexQueue.sync {
            fileSystemLookupFailuresForTesting[path] = (error, max(count, 0))
        }
    }

    func recordMaintenanceForTesting(_ metric: IndexMaintenanceOperationMetric) {
        recordMaintenance(metric)
    }

    func persistCheckpointForTesting(
        records: [FileRecord],
        roots rootURLs: [URL],
        pendingDirectories: [URL],
        activeDirectories: [URL] = [],
        completedDirectories: [URL] = [],
        operationStartedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        indexQueue.sync {
            let canonicalRoots = canonicalizedRoots(rootURLs)
            let store = HeapPagedRecordStore(records: records, roots: canonicalRoots.map(\.path))
            let progress = ScanCheckpointProgress(
                store: store,
                visited: records.count,
                pendingDirectories: pendingDirectories.map { $0.standardizedFileURL.path },
                activeDirectories: activeDirectories.map { $0.standardizedFileURL.path },
                completedDirectories: completedDirectories.map { $0.standardizedFileURL.path },
                operationStartedAt: operationStartedAt
            )
            persistScanCheckpoint(
                progress,
                roots: canonicalRoots.map(\.path),
                exclusionPatterns: lock.withLock { exclusionRules.patterns },
                generation: currentGeneration(),
                requiresActiveScan: false
            )
        }
    }

    func loadCheckpointForTesting(roots rootURLs: [URL]) -> Bool {
        let canonicalRoots = canonicalizedRoots(rootURLs)
        let generation = lock.withLock { () -> UInt64 in
            self.generation &+= 1
            activePathGramBuildGeneration = nil
            roots = canonicalRoots.map(\.path)
            indexing = true
            reconciling = false
            updating = false
            phase = .scanning
            activeOperationStartedAt = Date()
            return self.generation
        }
        guard let checkpoint = loadResumableScanCheckpoint(
            roots: canonicalRoots.map(\.path),
            exclusionPatterns: lock.withLock { exclusionRules.patterns }
        ) else {
            return false
        }
        applyLoadedScanCheckpoint(checkpoint, generation: generation)
        return true
    }

    func checkpointExistsForTesting() -> Bool {
        fileManager.fileExists(atPath: checkpointURL.path)
    }

    private func publishStats() {
        let update = lock.withLock {
            (
                stats: IndexStats(
                    indexedCount: searchSnapshot.resultCount,
                    isIndexing: indexing,
                    isReconciling: reconciling,
                    isUpdating: updating,
                    isLoadingSnapshot: snapshotLoadState == .loading,
                    phase: phase,
                    discoveredCount: discoveredCount,
                    searchableCount: searchableCount,
                    optimizedCount: optimizedCount,
                    snapshotRevision: searchSnapshotRevision,
                    status: status,
                    lastUpdated: lastUpdated,
                    activeOperationStartedAt: activeOperationStartedAt,
                    lastCheckpointAt: lastCheckpointAt,
                    resumedFromCheckpoint: resumedFromCheckpoint,
                    activityPresentation: activityPresentation
                ),
                handler: statsChangedHandler
            )
        }

        let stats = update.stats
        if let handler = update.handler {
            Task { @MainActor in
                handler(stats)
            }
        }

        if !stats.isIndexing {
            scheduleUpdateDrainIfNeeded(delay: .milliseconds(0))
            schedulePendingReconciliationDrainIfNeeded()
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
            isReconciling: reconciling,
            isUpdating: updating,
            isLoadingSnapshot: snapshotLoadState == .loading,
            phase: phase,
            discoveredCount: discoveredCount,
            searchableCount: searchableCount,
            optimizedCount: optimizedCount,
            snapshotRevision: searchSnapshotRevision,
            status: status,
            lastUpdated: lastUpdated,
            activeOperationStartedAt: activeOperationStartedAt,
            lastCheckpointAt: lastCheckpointAt,
            resumedFromCheckpoint: resumedFromCheckpoint,
            activityPresentation: activityPresentation
        )
    }

    public func recordExternalSearchStarted(phase: SearchMetricPhase) {
        recordSearchStarted(phase: phase)
    }

    public func recordExternalSearchCompleted(_ profile: SearchExecutionProfile, phase: SearchMetricPhase) {
        recordSearchCompleted(profile, phase: phase)
    }

    public func recordExternalSearchCancelled(phase: SearchMetricPhase, elapsed: TimeInterval) {
        recordSearchCancelled(phase: phase, elapsed: elapsed)
    }

    private func recordSearchStarted(phase: SearchMetricPhase) {
        updateUsageMetricsDeferred { metrics in
            metrics.recordSearchStarted(phase: phase)
        }
    }

    private func recordSearchCompleted(_ profile: SearchExecutionProfile, phase: SearchMetricPhase) {
        updateUsageMetricsDeferred { metrics in
            metrics.recordSearchCompleted(profile, phase: phase)
        }
    }

    private func recordSearchCancelled(phase: SearchMetricPhase, elapsed: TimeInterval) {
        updateUsageMetricsDeferred { metrics in
            metrics.recordSearchCancelled(phase: phase, elapsed: elapsed)
        }
    }

    private func recordFullRebuild(duration: TimeInterval) {
        updateUsageMetricsDeferred { metrics in
            metrics.recordFullRebuild(duration: duration)
        }
    }

    private func recordIncrementalRefresh(duration: TimeInterval) {
        updateUsageMetricsDeferred { metrics in
            metrics.recordIncrementalRefresh(duration: duration)
        }
    }

    private func recordIndexingFailure() {
        updateUsageMetricsDeferred { metrics in
            metrics.recordIndexingFailure()
        }
    }

    private func recordSnapshotLoadFailure(corruptSnapshotRemoved: Bool) {
        updateUsageMetricsDeferred { metrics in
            metrics.recordSnapshotLoadFailure(corruptSnapshotRemoved: corruptSnapshotRemoved)
        }
    }

    private func recordPersistFailure() {
        updateUsageMetricsDeferred { metrics in
            metrics.recordPersistFailure()
        }
    }

    private func recordTempCleanup(count: UInt64) {
        updateUsageMetricsDeferred { metrics in
            metrics.recordTempCleanup(count: count)
        }
    }

    private func recordMaintenance(_ metric: IndexMaintenanceOperationMetric) {
        let shouldScheduleSave = lock.withLock { () -> Bool in
            usageMetrics.recordMaintenance(metric)
            usageMetrics.schemaVersion = IndexUsageMetrics.currentSchemaVersion
            lastMaintenanceOperation = metric
            if metric.priority == .background || metric.kind == .backgroundSlice {
                lastBackgroundMaintenanceSlice = metric
            }
            markUsageMetricsDirtyWithoutLock()
            guard !usageMetricsSaveScheduled else { return false }
            usageMetricsSaveScheduled = true
            return true
        }
        if shouldScheduleSave {
            scheduleDeferredUsageMetricsSave()
        }
    }

    private func clearDeferredMaintenanceMarkers() {
        lock.withLock {
            deferredOptimizationReason = nil
            deferredOptimizationDelay = nil
            deferredCheckpointReason = nil
            deferredCheckpointDelay = nil
        }
    }

    private func clearDeferredOptimizationMarker() {
        lock.withLock {
            deferredOptimizationReason = nil
            deferredOptimizationDelay = nil
        }
    }

    private func clearDeferredCheckpointMarker() {
        lock.withLock {
            deferredCheckpointReason = nil
            deferredCheckpointDelay = nil
        }
    }

    private func recordDeferredOptimization(reason: String, delay: TimeInterval) {
        lock.withLock {
            deferredOptimizationReason = reason
            deferredOptimizationDelay = max(delay, 0)
        }
        recordMaintenance(IndexMaintenanceOperationMetric(
            kind: .optimization,
            priority: .background,
            optimizationDeferrals: 1
        ))
    }

    private func recordDeferredCheckpoint(reason: String, delay: TimeInterval) {
        lock.withLock {
            deferredCheckpointReason = reason
            deferredCheckpointDelay = max(delay, 0)
        }
    }

    private func updateUsageMetricsDeferred(_ body: (inout IndexUsageMetrics) -> Void) {
        let shouldScheduleSave = lock.withLock { () -> Bool in
            body(&usageMetrics)
            usageMetrics.schemaVersion = IndexUsageMetrics.currentSchemaVersion
            markUsageMetricsDirtyWithoutLock()
            guard !usageMetricsSaveScheduled else { return false }
            usageMetricsSaveScheduled = true
            return true
        }
        if shouldScheduleSave {
            scheduleDeferredUsageMetricsSave()
        }
    }

    private func scheduleDeferredUsageMetricsSave() {
        let delay = usageMetricsMaintenanceSaveDelay()
        metricsSaveQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.savePendingUsageMetricsIfNeeded()
        }
    }

    private func savePendingUsageMetricsIfNeeded() {
        let metrics = lock.withLock { () -> IndexUsageMetrics? in
            guard usageMetricsSavedGeneration != usageMetricsDirtyGeneration else {
                usageMetricsSaveScheduled = false
                return nil
            }
            markUsageMetricsSavedWithoutLock()
            return usageMetrics
        }
        guard let metrics else { return }
        Self.saveUsageMetrics(metrics, to: metricsURL, fileManager: fileManager)
    }

    private func markUsageMetricsDirtyWithoutLock() {
        usageMetricsDirtyGeneration &+= 1
    }

    private func markUsageMetricsSavedWithoutLock() {
        if usageMetricsSavedGeneration == usageMetricsDirtyGeneration {
            usageMetricsDirtyGeneration &+= 1
        }
        usageMetricsSavedGeneration = usageMetricsDirtyGeneration
        usageMetricsSaveScheduled = false
    }

    private static func loadUsageMetrics(from url: URL, fileManager: FileManager) -> IndexUsageMetrics {
        guard
            fileManager.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            var metrics = try? JSONDecoder().decode(IndexUsageMetrics.self, from: data)
        else {
            return IndexUsageMetrics(schemaVersion: IndexUsageMetrics.currentSchemaVersion)
        }

        switch metrics.schemaVersion {
        case IndexUsageMetrics.currentSchemaVersion:
            break
        case 1:
            metrics.schemaVersion = IndexUsageMetrics.currentSchemaVersion
            metrics.initialSearches = SearchUsageCounters()
            metrics.refinedSearches = SearchUsageCounters()
            for index in metrics.dailyBuckets.indices {
                metrics.dailyBuckets[index].initialSearches = SearchUsageCounters()
                metrics.dailyBuckets[index].refinedSearches = SearchUsageCounters()
            }
        case 2:
            metrics.schemaVersion = IndexUsageMetrics.currentSchemaVersion
        case 3:
            metrics.schemaVersion = IndexUsageMetrics.currentSchemaVersion
        case 4:
            metrics.schemaVersion = IndexUsageMetrics.currentSchemaVersion
            metrics.recentEnergySamples.removeAll()
            metrics.energyRollups.removeAll()
            for index in metrics.dailyBuckets.indices {
                metrics.dailyBuckets[index].energy = EnergyUsageBreakdown()
            }
        default:
            return IndexUsageMetrics(schemaVersion: IndexUsageMetrics.currentSchemaVersion)
        }

        metrics.pruneDailyBuckets()
        metrics.pruneEnergyHistory()
        return metrics
    }

    private static func saveUsageMetrics(_ metrics: IndexUsageMetrics, to url: URL, fileManager: FileManager) {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(metrics)
            try data.write(to: url, options: .atomic)
        } catch {
            MemoryTelemetry.log("metrics.save.failed")
        }
    }

    private func removeScanCheckpoint() {
        guard fileManager.fileExists(atPath: checkpointURL.path) else { return }
        if (try? fileManager.removeItem(at: checkpointURL)) != nil {
            recordTempCleanup(count: 1)
        }
    }

    private func removePersistedIndexFiles() throws {
        if fileManager.fileExists(atPath: snapshotURL.path) {
            try fileManager.removeItem(at: snapshotURL)
        }
        if fileManager.fileExists(atPath: checkpointURL.path) {
            try fileManager.removeItem(at: checkpointURL)
        }
        try structuralDeltaStore.clear()
        lock.withLock {
            structuralDelta = nil
            clearStructuralDeltaCompactionWithoutLock()
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
        let normalizedRoots = RootAttributionTable.normalizedRootPaths(roots)
        guard let table = snapshot.store.storedRootAttribution, table.isValid else {
            return normalizedRoots.map { root in
                IndexRootInsight(
                    path: root,
                    trackedFileCount: 0,
                    directoryCount: 0,
                    hiddenCount: 0,
                    indexedContentBytes: 0,
                    pathByteWeight: 0,
                    estimatedIndexBytes: 0,
                    attributionSource: .estimated
                )
            }
        }

        let summariesByPath = Dictionary(uniqueKeysWithValues: table.roots.map { ($0.path, $0) })
        let totalWeight = table.roots.reduce(UInt64(0)) { $0 &+ $1.pathByteWeight }
        let source: IndexRootAttributionSource = snapshot.store.kind == .mapped ? .persistedExact : .runtimeExact

        return normalizedRoots.map { root in
            let storedSummary = summariesByPath[root]
            let value = storedSummary ?? RootAttributionSummary(id: RootAttributionTable.unassignedRootID, path: root)
            let estimatedBytes = totalWeight == 0
                ? 0
                : UInt64((Double(value.pathByteWeight) / Double(totalWeight) * Double(estimatedIndexBytes)).rounded())
            return IndexRootInsight(
                path: root,
                trackedFileCount: value.trackedFileCount,
                directoryCount: value.directoryCount,
                hiddenCount: value.hiddenCount,
                indexedContentBytes: value.indexedContentBytes,
                pathByteWeight: value.pathByteWeight,
                estimatedIndexBytes: estimatedBytes,
                attributionSource: storedSummary == nil ? .estimated : source
            )
        }
    }

    private func currentStorageInsights() -> IndexStorageInsights {
        let package = Self.packageStorageInsights(snapshotURL: snapshotURL, fileManager: fileManager)
        let cached = storageInsightsLock.withLock { cachedStorageInsights }
        scheduleStorageInsightsRefreshIfNeeded()

        guard let cached else {
            return IndexStorageInsights(
                totalATTDataBytes: package.indexPackageBytes,
                indexPackageBytes: package.indexPackageBytes,
                indexPackageCreatedAt: package.indexPackageCreatedAt,
                cacheBytes: 0,
                measuredAt: nil,
                isMeasuring: true,
                locations: [],
                sidecars: package.sidecars
            )
        }

        return IndexStorageInsights(
            totalATTDataBytes: max(cached.totalATTDataBytes, package.indexPackageBytes),
            indexPackageBytes: package.indexPackageBytes,
            indexPackageCreatedAt: package.indexPackageCreatedAt,
            cacheBytes: cached.cacheBytes,
            measuredAt: cached.measuredAt,
            isMeasuring: storageInsightsLock.withLock { storageInsightsRefreshInFlight },
            locations: cached.locations,
            sidecars: package.sidecars
        )
    }

    private func scheduleStorageInsightsRefreshIfNeeded() {
        let shouldStart = storageInsightsLock.withLock { () -> Bool in
            guard !storageInsightsRefreshInFlight else { return false }
            if let measuredAt = cachedStorageInsights?.measuredAt, Date().timeIntervalSince(measuredAt) < 60 {
                return false
            }
            storageInsightsRefreshInFlight = true
            return true
        }

        guard shouldStart else { return }

        let supportDirectory = supportDirectory
        let snapshotURL = snapshotURL
        let applicationName = supportDirectory.lastPathComponent
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let measured = Self.storageInsights(
                supportDirectory: supportDirectory,
                snapshotURL: snapshotURL,
                applicationName: applicationName,
                fileManager: self.fileManager
            )
            self.storageInsightsLock.withLock {
                self.cachedStorageInsights = measured
                self.storageInsightsRefreshInFlight = false
            }
        }
    }

    private func invalidateStorageInsightsCache() {
        storageInsightsLock.withLock {
            cachedStorageInsights = nil
        }
    }

    private static func packageStorageInsights(
        snapshotURL: URL,
        fileManager: FileManager
    ) -> (indexPackageBytes: UInt64, indexPackageCreatedAt: Date?, sidecars: [IndexSidecarInsight]) {
        let sidecars = sidecarInsights(in: snapshotURL, fileManager: fileManager)
        let packageBytes = sidecars.reduce(UInt64(0)) { $0 &+ $1.allocatedBytes }
        return (packageBytes, creationDate(of: snapshotURL, fileManager: fileManager), sidecars)
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
            indexPackageCreatedAt: creationDate(of: snapshotURL, fileManager: fileManager),
            cacheBytes: cacheBytes,
            measuredAt: Date(),
            isMeasuring: false,
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
                    allocatedBytes: allocatedSize(of: url, fileManager: fileManager, maximumDescendants: 0)
                )
            }
            .sorted {
                if $0.allocatedBytes != $1.allocatedBytes {
                    return $0.allocatedBytes > $1.allocatedBytes
                }
                return $0.name < $1.name
            }
    }

    private static func creationDate(of url: URL, fileManager: FileManager) -> Date? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    private static func allocatedSize(
        of url: URL,
        fileManager: FileManager,
        maximumDescendants: Int = Int.max
    ) -> UInt64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }

        var total: UInt64 = allocatedFileSize(of: url)
        guard maximumDescendants != 0 else { return total }

        var visited = 0
        if let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) {
            for case let child as URL in enumerator {
                total &+= allocatedFileSize(of: child)
                visited += 1
                if visited >= maximumDescendants {
                    break
                }
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

    private func isSnapshotRevisionCurrent(_ candidate: UInt64) -> Bool {
        lock.withLock {
            searchSnapshotRevision == candidate
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

    private static func reconciliationScopeURLs(for requestedPaths: [String], within rootPaths: [String]) -> [URL] {
        let allowedPaths = requestedPaths.filter { requestedPath in
            rootPaths.contains { requestedPath == $0 || requestedPath.hasPrefix($0 + "/") }
        }
        var collapsed: [String] = []
        for path in allowedPaths.sorted(by: { $0.count < $1.count }) {
            guard !collapsed.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
                continue
            }
            collapsed.append(path)
        }
        return collapsed.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    }

    private static func path(_ path: String, isContainedIn rootPaths: [String]) -> Bool {
        rootPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func makeExclusionQuery(
        exclusions: FileExclusionRules,
        rootPaths: [String],
        evaluationMode: ExclusionEvaluationMode
    ) -> FileExclusionQuery? {
        switch evaluationMode {
        case .compiledQuery:
            return exclusions.makeQuery(roots: rootPaths)
        case .legacyRules:
            return nil
        }
    }

    private func exclusionDecision(
        for url: URL,
        exclusions: FileExclusionRules,
        rootPaths: [String],
        query: FileExclusionQuery?,
        isDirectory: Bool? = nil
    ) -> FileExclusionRules.Decision {
        var instrumentation = FileExclusionQuery.Instrumentation()
        return exclusionDecision(
            for: url,
            exclusions: exclusions,
            rootPaths: rootPaths,
            query: query,
            isDirectory: isDirectory,
            instrumentation: &instrumentation
        )
    }

    private func exclusionDecision(
        for url: URL,
        exclusions: FileExclusionRules,
        rootPaths: [String],
        query: FileExclusionQuery?,
        isDirectory: Bool? = nil,
        instrumentation: inout FileExclusionQuery.Instrumentation
    ) -> FileExclusionRules.Decision {
        if let query, let isDirectory {
            return query.decision(path: url.path, isDirectory: isDirectory, instrumentation: &instrumentation)
        }
        return exclusions.decision(url: url, roots: rootPaths, isDirectory: isDirectory)
    }

    private func canScanDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        guard let stream = openDirectoryStream(url) else { return false }
        defer { closedir(stream) }
        errno = 0
        _ = readdir(stream)
        return errno == 0
    }

    private func openDirectoryStream(_ directory: URL) -> UnsafeMutablePointer<DIR>? {
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

    private func logSkippedRoot(_ root: URL, reason: String) {
        DiagnosticLogger.shared.log(
            level: .warning,
            category: "index",
            event: "index.rootSkipped",
            fields: [
                "reason": .publicString(reason),
                "root": .path(root.path)
            ]
        )
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
            lhs: lhs,
            lhsScore: lhs.score,
            lhsMatch: lhs.match,
            rhs: rhs,
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
            primary = ordered(kindName(for: lhs), kindName(for: rhs))
        case .volume:
            primary = ordered(lhs.volumeName, rhs.volumeName)
        case .root:
            primary = ordered(lhs.rootPath ?? "", rhs.rootPath ?? "")
        }

        if let primary {
            return primary
        }

        if lhs.normalizedName != rhs.normalizedName {
            return lhs.normalizedName < rhs.normalizedName
        }

        return lhs.path < rhs.path
    }

    private static func kindName<Record: SearchRecordReadable>(for record: Record) -> String {
        record.isDirectory && record.fileExtension == "app" ? "Application" : (record.isDirectory ? "Folder" : "File")
    }

    private static func diagnosticRebuildModeString(_ mode: RebuildMode) -> String {
        switch mode {
        case .resumeIfAvailable:
            return "resumeIfAvailable"
        case .fresh:
            return "fresh"
        }
    }
}

private extension FileRecord {
    static func fileIndexStatDerived(
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
        let isHidden = pathIsHidden(path)
            || (statBlock.st_flags & UInt32(bitPattern: UF_HIDDEN)) != 0

        return FileRecord(
            id: stableID(for: path),
            path: path,
            name: name,
            directoryPath: directoryPath,
            fileExtension: (name as NSString).pathExtension.lowercased(),
            sizeBytes: isDirectory ? 0 : size,
            modifiedTime: modifiedTime,
            createdTime: createdTime,
            isDirectory: isDirectory,
            isHidden: isHidden,
            volumeName: volumeName,
            normalizedName: FuzzyMatcher.normalize(name),
            normalizedPath: FuzzyMatcher.normalize(path)
        )
    }

    private static func timeIntervalSinceReferenceDate(_ timespec: timespec) -> TimeInterval {
        Date(
            timeIntervalSince1970: TimeInterval(timespec.tv_sec)
                + TimeInterval(timespec.tv_nsec) / 1_000_000_000
        ).timeIntervalSinceReferenceDate
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff)
        ])
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        append(contentsOf: [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 32) & 0xff),
            UInt8((value >> 40) & 0xff),
            UInt8((value >> 48) & 0xff),
            UInt8((value >> 56) & 0xff)
        ])
    }

    mutating func appendLengthPrefixedUTF8(_ value: String, maximumByteCount: Int) throws {
        let bytes = Array(value.utf8)
        guard bytes.count <= maximumByteCount, bytes.count <= Int(UInt32.max) else {
            throw CocoaError(.fileWriteUnknown)
        }
        appendUInt32LE(UInt32(bytes.count))
        append(contentsOf: bytes)
    }
}
