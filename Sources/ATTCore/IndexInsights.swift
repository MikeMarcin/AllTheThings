import Foundation

public enum SearchExecutionPath: String, Codable, CaseIterable, Sendable {
    case emptyQuerySortedOrder
    case nameComponentIndex
    case pathGramIndex
    case extensionCandidateIntersection
    case optimizedSortedFastPath
    case fullFallbackScan
    case indexedCandidateIntersection
    case unprofiledIndexed
    case unprofiled
}

public enum SearchIndexUse: String, Codable, CaseIterable, Hashable, Sendable {
    case nameGrams
    case componentGrams
    case pathGrams
    case extensionPostings
    case modifiedOrder
    case visibleBitset
}

public struct SearchExecutionProfile: Codable, Equatable, Sendable {
    public let executionPath: SearchExecutionPath
    public let indexesUsed: Set<SearchIndexUse>
    public let candidateCount: Int
    public let scannedRowCount: Int
    public let didFallbackToFullScan: Bool
    public let wasCancelled: Bool
    public let wasStaleRetry: Bool
    public let elapsed: TimeInterval

    public init(
        executionPath: SearchExecutionPath,
        indexesUsed: Set<SearchIndexUse> = [],
        candidateCount: Int = 0,
        scannedRowCount: Int = 0,
        didFallbackToFullScan: Bool = false,
        wasCancelled: Bool = false,
        wasStaleRetry: Bool = false,
        elapsed: TimeInterval = 0
    ) {
        self.executionPath = executionPath
        self.indexesUsed = indexesUsed
        self.candidateCount = max(candidateCount, 0)
        self.scannedRowCount = max(scannedRowCount, 0)
        self.didFallbackToFullScan = didFallbackToFullScan
        self.wasCancelled = wasCancelled
        self.wasStaleRetry = wasStaleRetry
        self.elapsed = max(elapsed, 0)
    }
}

public enum FileActionMetric: String, Codable, CaseIterable, Sendable {
    case open
    case reveal
    case copyFile
    case copyPath
    case quickLook
    case rename
    case moveToTrash
    case getInfo
}

public struct IndexStorageLocationInsight: Codable, Equatable, Sendable {
    public let label: String
    public let path: String
    public let allocatedBytes: UInt64

    public init(label: String, path: String, allocatedBytes: UInt64) {
        self.label = label
        self.path = path
        self.allocatedBytes = allocatedBytes
    }
}

public struct IndexSidecarInsight: Codable, Equatable, Sendable {
    public let name: String
    public let allocatedBytes: UInt64

    public init(name: String, allocatedBytes: UInt64) {
        self.name = name
        self.allocatedBytes = allocatedBytes
    }
}

public struct IndexRootInsight: Codable, Equatable, Sendable {
    public let path: String
    public let trackedFileCount: Int
    public let directoryCount: Int
    public let hiddenCount: Int
    public let indexedContentBytes: UInt64
    public let pathByteWeight: UInt64
    public let estimatedIndexBytes: UInt64

    public init(
        path: String,
        trackedFileCount: Int,
        directoryCount: Int,
        hiddenCount: Int,
        indexedContentBytes: UInt64,
        pathByteWeight: UInt64,
        estimatedIndexBytes: UInt64
    ) {
        self.path = path
        self.trackedFileCount = trackedFileCount
        self.directoryCount = directoryCount
        self.hiddenCount = hiddenCount
        self.indexedContentBytes = indexedContentBytes
        self.pathByteWeight = pathByteWeight
        self.estimatedIndexBytes = estimatedIndexBytes
    }
}

public struct IndexStorageInsights: Codable, Equatable, Sendable {
    public let totalATTDataBytes: UInt64
    public let indexPackageBytes: UInt64
    public let cacheBytes: UInt64
    public let locations: [IndexStorageLocationInsight]
    public let sidecars: [IndexSidecarInsight]

    public init(
        totalATTDataBytes: UInt64,
        indexPackageBytes: UInt64,
        cacheBytes: UInt64,
        locations: [IndexStorageLocationInsight],
        sidecars: [IndexSidecarInsight]
    ) {
        self.totalATTDataBytes = totalATTDataBytes
        self.indexPackageBytes = indexPackageBytes
        self.cacheBytes = cacheBytes
        self.locations = locations
        self.sidecars = sidecars
    }
}

public struct SearchUsageCounters: Codable, Equatable, Sendable {
    public var started: UInt64
    public var completed: UInt64
    public var cancelled: UInt64
    public var staleRetries: UInt64
    public var indexedCandidateSearches: UInt64
    public var fallbackScans: UInt64
    public var totalLatency: TimeInterval
    public var maxLatency: TimeInterval
    public var candidateRowsExamined: UInt64
    public var scannedRowsExamined: UInt64
    public var latencyBuckets: [String: UInt64]
    public var executionPathCounts: [SearchExecutionPath: UInt64]
    public var indexUseCounts: [SearchIndexUse: UInt64]

    public init(
        started: UInt64 = 0,
        completed: UInt64 = 0,
        cancelled: UInt64 = 0,
        staleRetries: UInt64 = 0,
        indexedCandidateSearches: UInt64 = 0,
        fallbackScans: UInt64 = 0,
        totalLatency: TimeInterval = 0,
        maxLatency: TimeInterval = 0,
        candidateRowsExamined: UInt64 = 0,
        scannedRowsExamined: UInt64 = 0,
        latencyBuckets: [String: UInt64] = [:],
        executionPathCounts: [SearchExecutionPath: UInt64] = [:],
        indexUseCounts: [SearchIndexUse: UInt64] = [:]
    ) {
        self.started = started
        self.completed = completed
        self.cancelled = cancelled
        self.staleRetries = staleRetries
        self.indexedCandidateSearches = indexedCandidateSearches
        self.fallbackScans = fallbackScans
        self.totalLatency = totalLatency
        self.maxLatency = maxLatency
        self.candidateRowsExamined = candidateRowsExamined
        self.scannedRowsExamined = scannedRowsExamined
        self.latencyBuckets = latencyBuckets
        self.executionPathCounts = executionPathCounts
        self.indexUseCounts = indexUseCounts
    }

    public var averageLatency: TimeInterval {
        completed == 0 ? 0 : totalLatency / Double(completed)
    }
}

public struct IndexHealthCounters: Codable, Equatable, Sendable {
    public var fullRebuilds: UInt64
    public var incrementalRefreshBatches: UInt64
    public var recursiveRescans: UInt64
    public var indexingFailures: UInt64
    public var snapshotLoadFailures: UInt64
    public var corruptSnapshotRemovals: UInt64
    public var persistFailures: UInt64
    public var tempCleanupCount: UInt64
    public var activeJobHighWaterMark: Int
    public var initialBuildDuration: TimeInterval?
    public var lastRebuildDuration: TimeInterval?
    public var totalRebuildDuration: TimeInterval
    public var lastRefreshDuration: TimeInterval?
    public var totalRefreshDuration: TimeInterval

    public init(
        fullRebuilds: UInt64 = 0,
        incrementalRefreshBatches: UInt64 = 0,
        recursiveRescans: UInt64 = 0,
        indexingFailures: UInt64 = 0,
        snapshotLoadFailures: UInt64 = 0,
        corruptSnapshotRemovals: UInt64 = 0,
        persistFailures: UInt64 = 0,
        tempCleanupCount: UInt64 = 0,
        activeJobHighWaterMark: Int = 0,
        initialBuildDuration: TimeInterval? = nil,
        lastRebuildDuration: TimeInterval? = nil,
        totalRebuildDuration: TimeInterval = 0,
        lastRefreshDuration: TimeInterval? = nil,
        totalRefreshDuration: TimeInterval = 0
    ) {
        self.fullRebuilds = fullRebuilds
        self.incrementalRefreshBatches = incrementalRefreshBatches
        self.recursiveRescans = recursiveRescans
        self.indexingFailures = indexingFailures
        self.snapshotLoadFailures = snapshotLoadFailures
        self.corruptSnapshotRemovals = corruptSnapshotRemovals
        self.persistFailures = persistFailures
        self.tempCleanupCount = tempCleanupCount
        self.activeJobHighWaterMark = activeJobHighWaterMark
        self.initialBuildDuration = initialBuildDuration
        self.lastRebuildDuration = lastRebuildDuration
        self.totalRebuildDuration = totalRebuildDuration
        self.lastRefreshDuration = lastRefreshDuration
        self.totalRefreshDuration = totalRefreshDuration
    }
}

public struct MemoryUsageCounters: Codable, Equatable, Sendable {
    public var latestBytes: UInt64
    public var dailyMinimumBytes: UInt64
    public var dailyMaximumBytes: UInt64

    public init(latestBytes: UInt64 = 0, dailyMinimumBytes: UInt64 = 0, dailyMaximumBytes: UInt64 = 0) {
        self.latestBytes = latestBytes
        self.dailyMinimumBytes = dailyMinimumBytes
        self.dailyMaximumBytes = dailyMaximumBytes
    }
}

public struct DailyUsageBucket: Codable, Equatable, Sendable, Identifiable {
    public let day: String
    public var searches: SearchUsageCounters
    public var fileActions: [FileActionMetric: UInt64]
    public var health: IndexHealthCounters
    public var launches: UInt64
    public var memory: MemoryUsageCounters

    public var id: String { day }

    public init(
        day: String,
        searches: SearchUsageCounters = SearchUsageCounters(),
        fileActions: [FileActionMetric: UInt64] = [:],
        health: IndexHealthCounters = IndexHealthCounters(),
        launches: UInt64 = 0,
        memory: MemoryUsageCounters = MemoryUsageCounters()
    ) {
        self.day = day
        self.searches = searches
        self.fileActions = fileActions
        self.health = health
        self.launches = launches
        self.memory = memory
    }
}

public struct AppLifetimeMetrics: Codable, Equatable, Sendable {
    public var firstLaunchDate: Date?
    public var launchCount: UInt64
    public var currentAppVersionFirstSeen: String?
    public var currentAppVersionFirstSeenDate: Date?

    public init(
        firstLaunchDate: Date? = nil,
        launchCount: UInt64 = 0,
        currentAppVersionFirstSeen: String? = nil,
        currentAppVersionFirstSeenDate: Date? = nil
    ) {
        self.firstLaunchDate = firstLaunchDate
        self.launchCount = launchCount
        self.currentAppVersionFirstSeen = currentAppVersionFirstSeen
        self.currentAppVersionFirstSeenDate = currentAppVersionFirstSeenDate
    }
}

public struct IndexUsageMetrics: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var lifetime: AppLifetimeMetrics
    public var allTimeSearches: SearchUsageCounters
    public var allTimeFileActions: [FileActionMetric: UInt64]
    public var health: IndexHealthCounters
    public var dailyBuckets: [DailyUsageBucket]

    public init(
        schemaVersion: Int = 1,
        lifetime: AppLifetimeMetrics = AppLifetimeMetrics(),
        allTimeSearches: SearchUsageCounters = SearchUsageCounters(),
        allTimeFileActions: [FileActionMetric: UInt64] = [:],
        health: IndexHealthCounters = IndexHealthCounters(),
        dailyBuckets: [DailyUsageBucket] = []
    ) {
        self.schemaVersion = schemaVersion
        self.lifetime = lifetime
        self.allTimeSearches = allTimeSearches
        self.allTimeFileActions = allTimeFileActions
        self.health = health
        self.dailyBuckets = dailyBuckets
    }
}

public struct IndexHealthDiagnostics: Codable, Equatable, Sendable {
    public let phase: IndexPhase
    public let status: String
    public let activeIndexJobs: Int
    public let activeIndexJobHighWaterMark: Int
    public let schemaVersion: Int
    public let snapshotRevision: UInt64
    public let recordStoreKind: String
    public let mappedByteSize: Int
    public let heapPageCount: Int
    public let overlayCount: Int
    public let columnarSidecarsLoaded: Bool
    public let resultCount: Int
    public let virtualRowCount: Int
    public let visibleCount: Int?
    public let pathGramIndexEnabled: Bool
    public let nameGramKeyCount: Int
    public let componentGramKeyCount: Int
    public let pathGramKeyCount: Int
    public let extensionKeyCount: Int
    public let completedRefreshBatches: UInt64
    public let completedSnapshotRebuilds: UInt64
    public let fallbackScanCount: UInt64
    public let scannedRowCount: UInt64
    public let pathMaterializationCount: UInt64
    public let canClearCachedIndex: Bool

    public init(
        phase: IndexPhase,
        status: String,
        activeIndexJobs: Int,
        activeIndexJobHighWaterMark: Int,
        schemaVersion: Int,
        snapshotRevision: UInt64,
        recordStoreKind: String,
        mappedByteSize: Int,
        heapPageCount: Int,
        overlayCount: Int,
        columnarSidecarsLoaded: Bool,
        resultCount: Int,
        virtualRowCount: Int,
        visibleCount: Int?,
        pathGramIndexEnabled: Bool,
        nameGramKeyCount: Int,
        componentGramKeyCount: Int,
        pathGramKeyCount: Int,
        extensionKeyCount: Int,
        completedRefreshBatches: UInt64,
        completedSnapshotRebuilds: UInt64,
        fallbackScanCount: UInt64,
        scannedRowCount: UInt64,
        pathMaterializationCount: UInt64,
        canClearCachedIndex: Bool
    ) {
        self.phase = phase
        self.status = status
        self.activeIndexJobs = activeIndexJobs
        self.activeIndexJobHighWaterMark = activeIndexJobHighWaterMark
        self.schemaVersion = schemaVersion
        self.snapshotRevision = snapshotRevision
        self.recordStoreKind = recordStoreKind
        self.mappedByteSize = mappedByteSize
        self.heapPageCount = heapPageCount
        self.overlayCount = overlayCount
        self.columnarSidecarsLoaded = columnarSidecarsLoaded
        self.resultCount = resultCount
        self.virtualRowCount = virtualRowCount
        self.visibleCount = visibleCount
        self.pathGramIndexEnabled = pathGramIndexEnabled
        self.nameGramKeyCount = nameGramKeyCount
        self.componentGramKeyCount = componentGramKeyCount
        self.pathGramKeyCount = pathGramKeyCount
        self.extensionKeyCount = extensionKeyCount
        self.completedRefreshBatches = completedRefreshBatches
        self.completedSnapshotRebuilds = completedSnapshotRebuilds
        self.fallbackScanCount = fallbackScanCount
        self.scannedRowCount = scannedRowCount
        self.pathMaterializationCount = pathMaterializationCount
        self.canClearCachedIndex = canClearCachedIndex
    }
}

public struct IndexInsightsSnapshot: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let stats: IndexStats
    public let roots: [IndexRootInsight]
    public let storage: IndexStorageInsights
    public let usage: IndexUsageMetrics
    public let lifetime: AppLifetimeMetrics
    public let health: IndexHealthDiagnostics

    public init(
        generatedAt: Date,
        stats: IndexStats,
        roots: [IndexRootInsight],
        storage: IndexStorageInsights,
        usage: IndexUsageMetrics,
        lifetime: AppLifetimeMetrics,
        health: IndexHealthDiagnostics
    ) {
        self.generatedAt = generatedAt
        self.stats = stats
        self.roots = roots
        self.storage = storage
        self.usage = usage
        self.lifetime = lifetime
        self.health = health
    }
}

extension IndexUsageMetrics {
    static let currentSchemaVersion = 1
    static let retainedDailyBucketCount = 365

    mutating func recordAppLaunch(appVersion: String?, at date: Date = Date()) {
        if lifetime.firstLaunchDate == nil {
            lifetime.firstLaunchDate = date
        }
        lifetime.launchCount &+= 1

        if let appVersion, lifetime.currentAppVersionFirstSeen != appVersion {
            lifetime.currentAppVersionFirstSeen = appVersion
            lifetime.currentAppVersionFirstSeenDate = date
        }

        mutateDailyBucket(for: date) { bucket in
            bucket.launches &+= 1
        }
        pruneDailyBuckets()
    }

    mutating func recordSearchStarted(at date: Date = Date()) {
        allTimeSearches.started &+= 1
        mutateDailyBucket(for: date) { bucket in
            bucket.searches.started &+= 1
        }
        pruneDailyBuckets()
    }

    mutating func recordSearchCompleted(_ profile: SearchExecutionProfile, at date: Date = Date()) {
        Self.applyCompletedSearch(profile, to: &allTimeSearches)
        mutateDailyBucket(for: date) { bucket in
            Self.applyCompletedSearch(profile, to: &bucket.searches)
        }
        pruneDailyBuckets()
    }

    mutating func recordSearchCancelled(elapsed: TimeInterval, at date: Date = Date()) {
        let profile = SearchExecutionProfile(
            executionPath: .unprofiled,
            wasCancelled: true,
            elapsed: elapsed
        )
        allTimeSearches.cancelled &+= 1
        mutateDailyBucket(for: date) { bucket in
            bucket.searches.cancelled &+= 1
            Self.applyLatency(profile.elapsed, to: &bucket.searches)
        }
        Self.applyLatency(profile.elapsed, to: &allTimeSearches)
        pruneDailyBuckets()
    }

    mutating func recordFileAction(_ action: FileActionMetric, at date: Date = Date()) {
        allTimeFileActions[action, default: 0] &+= 1
        mutateDailyBucket(for: date) { bucket in
            bucket.fileActions[action, default: 0] &+= 1
        }
        pruneDailyBuckets()
    }

    mutating func recordFullRebuild(duration: TimeInterval, at date: Date = Date()) {
        if health.initialBuildDuration == nil {
            health.initialBuildDuration = duration
        }
        health.fullRebuilds &+= 1
        health.lastRebuildDuration = duration
        health.totalRebuildDuration += max(duration, 0)

        mutateDailyBucket(for: date) { bucket in
            bucket.health.fullRebuilds &+= 1
            bucket.health.lastRebuildDuration = duration
            bucket.health.totalRebuildDuration += max(duration, 0)
        }
        pruneDailyBuckets()
    }

    mutating func recordIncrementalRefresh(duration: TimeInterval, at date: Date = Date()) {
        health.incrementalRefreshBatches &+= 1
        health.lastRefreshDuration = duration
        health.totalRefreshDuration += max(duration, 0)

        mutateDailyBucket(for: date) { bucket in
            bucket.health.incrementalRefreshBatches &+= 1
            bucket.health.lastRefreshDuration = duration
            bucket.health.totalRefreshDuration += max(duration, 0)
        }
        pruneDailyBuckets()
    }

    mutating func recordRecursiveRescan(at date: Date = Date()) {
        health.recursiveRescans &+= 1
        mutateDailyBucket(for: date) { bucket in
            bucket.health.recursiveRescans &+= 1
        }
        pruneDailyBuckets()
    }

    mutating func recordIndexingFailure(at date: Date = Date()) {
        health.indexingFailures &+= 1
        mutateDailyBucket(for: date) { bucket in
            bucket.health.indexingFailures &+= 1
        }
        pruneDailyBuckets()
    }

    mutating func recordSnapshotLoadFailure(corruptSnapshotRemoved: Bool, at date: Date = Date()) {
        health.snapshotLoadFailures &+= 1
        mutateDailyBucket(for: date) { bucket in
            bucket.health.snapshotLoadFailures &+= 1
            if corruptSnapshotRemoved {
                bucket.health.corruptSnapshotRemovals &+= 1
            }
        }
        if corruptSnapshotRemoved {
            health.corruptSnapshotRemovals &+= 1
        }
        pruneDailyBuckets()
    }

    mutating func recordPersistFailure(at date: Date = Date()) {
        health.persistFailures &+= 1
        mutateDailyBucket(for: date) { bucket in
            bucket.health.persistFailures &+= 1
        }
        pruneDailyBuckets()
    }

    mutating func recordTempCleanup(count: UInt64, at date: Date = Date()) {
        guard count > 0 else { return }
        health.tempCleanupCount &+= count
        mutateDailyBucket(for: date) { bucket in
            bucket.health.tempCleanupCount &+= count
        }
        pruneDailyBuckets()
    }

    mutating func recordActiveJobHighWaterMark(_ value: Int) {
        health.activeJobHighWaterMark = max(health.activeJobHighWaterMark, value)
    }

    mutating func recordMemorySample(bytes: UInt64, at date: Date = Date()) {
        guard bytes > 0 else { return }
        mutateDailyBucket(for: date) { bucket in
            bucket.memory.latestBytes = bytes
            bucket.memory.dailyMinimumBytes = bucket.memory.dailyMinimumBytes == 0
                ? bytes
                : min(bucket.memory.dailyMinimumBytes, bytes)
            bucket.memory.dailyMaximumBytes = max(bucket.memory.dailyMaximumBytes, bytes)
        }
        pruneDailyBuckets()
    }

    mutating func pruneDailyBuckets(limit: Int = retainedDailyBucketCount) {
        guard dailyBuckets.count > limit else { return }
        dailyBuckets.sort { $0.day < $1.day }
        dailyBuckets.removeFirst(dailyBuckets.count - limit)
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private mutating func dailyBucket(for date: Date) -> DailyUsageBucket {
        let day = Self.dayKey(for: date)
        if let bucket = dailyBuckets.first(where: { $0.day == day }) {
            return bucket
        }
        let bucket = DailyUsageBucket(day: day)
        dailyBuckets.append(bucket)
        dailyBuckets.sort { $0.day < $1.day }
        return bucket
    }

    private mutating func replaceDailyBucket(_ bucket: DailyUsageBucket) {
        if let index = dailyBuckets.firstIndex(where: { $0.day == bucket.day }) {
            dailyBuckets[index] = bucket
        } else {
            dailyBuckets.append(bucket)
            dailyBuckets.sort { $0.day < $1.day }
        }
    }

    private mutating func mutateDailyBucket(for date: Date, _ body: (inout DailyUsageBucket) -> Void) {
        var bucket = dailyBucket(for: date)
        body(&bucket)
        replaceDailyBucket(bucket)
    }

    private static func applyCompletedSearch(_ profile: SearchExecutionProfile, to counters: inout SearchUsageCounters) {
        counters.completed &+= 1
        if profile.wasCancelled {
            counters.cancelled &+= 1
        }
        if profile.wasStaleRetry {
            counters.staleRetries &+= 1
        }
        if !profile.indexesUsed.isEmpty {
            counters.indexedCandidateSearches &+= 1
        }
        if profile.didFallbackToFullScan {
            counters.fallbackScans &+= 1
        }

        counters.candidateRowsExamined &+= UInt64(max(profile.candidateCount, 0))
        counters.scannedRowsExamined &+= UInt64(max(profile.scannedRowCount, 0))
        counters.executionPathCounts[profile.executionPath, default: 0] &+= 1

        for indexUse in profile.indexesUsed {
            counters.indexUseCounts[indexUse, default: 0] &+= 1
        }

        applyLatency(profile.elapsed, to: &counters)
    }

    private static func applyLatency(_ elapsed: TimeInterval, to counters: inout SearchUsageCounters) {
        let boundedElapsed = max(elapsed, 0)
        counters.totalLatency += boundedElapsed
        counters.maxLatency = max(counters.maxLatency, boundedElapsed)
        counters.latencyBuckets[Self.latencyBucket(for: boundedElapsed), default: 0] &+= 1
    }

    private static func latencyBucket(for elapsed: TimeInterval) -> String {
        switch elapsed {
        case ..<0.01: "<10ms"
        case ..<0.05: "10-50ms"
        case ..<0.1: "50-100ms"
        case ..<0.25: "100-250ms"
        case ..<1.0: "250ms-1s"
        default: ">1s"
        }
    }
}
