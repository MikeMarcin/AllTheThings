import CoreServices
import ATTCore
import Foundation

struct FileSystemEvent: Sendable {
    let path: String
    let flags: FSEventStreamEventFlags
    let eventID: FSEventStreamEventId

    var historyReplayCompleted: Bool {
        flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0
    }

    var historyIsUnsafe: Bool {
        invalidatesEntireStream
            || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
    }

    var invalidatesEntireStream: Bool {
        flags & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) != 0
            || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped) != 0
            || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped) != 0
    }

    var eventIDsWrapped: Bool {
        flags & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped) != 0
    }

    var requiresRecursiveRescan: Bool {
        flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
            || historyIsUnsafe
    }

    var itemIsDirectory: Bool {
        flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
    }

    var itemChangeRequiresDirectoryScope: Bool {
        flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0
            || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0
    }

    var requiresDirectoryRefreshScope: Bool {
        itemIsDirectory || requiresRecursiveRescan || itemChangeRequiresDirectoryScope
    }

    func merging(_ other: FileSystemEvent) -> FileSystemEvent {
        FileSystemEvent(
            path: path,
            flags: flags | other.flags,
            eventID: max(eventID, other.eventID)
        )
    }
}

enum ApplicationSearchEventFilter {
    static func shouldInvalidate(events: [FileSystemEvent], roots: [URL]) -> Bool {
        let rootPaths = roots.map { $0.standardizedFileURL.path }
        guard !rootPaths.isEmpty else { return false }
        return events.contains { event in
            if event.historyIsUnsafe {
                return true
            }
            return rootPaths.contains { root in
                event.path == root || event.path.hasPrefix(root + "/")
            }
        }
    }
}

enum FSEventCursorAdvances {
    static func latestByRoot(
        events: [FileSystemEvent],
        rootPaths: [String],
        wrappedBaselineEventID: UInt64? = nil
    ) -> [String: UInt64] {
        guard !events.isEmpty, !rootPaths.isEmpty else { return [:] }

        let rootPaths = rootPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        if
            let wrappedBaselineEventID,
            events.contains(where: \.eventIDsWrapped)
        {
            return Dictionary(uniqueKeysWithValues: rootPaths.map { ($0, wrappedBaselineEventID) })
        }

        var latestByRoot: [String: UInt64] = [:]
        for event in events {
            if event.historyIsUnsafe {
                for root in rootPaths {
                    latestByRoot[root] = max(latestByRoot[root] ?? 0, UInt64(event.eventID))
                }
                continue
            }

            let path = URL(fileURLWithPath: event.path).standardizedFileURL.path
            guard let root = rootPaths.first(where: { root in
                root == "/" || path == root || path.hasPrefix(root + "/")
            }) else {
                continue
            }
            latestByRoot[root] = max(latestByRoot[root] ?? 0, UInt64(event.eventID))
        }
        return latestByRoot
    }
}

enum FSEventDefaultExclusionPolicy {
    private static let orderedRules = FileExclusionRules.defaultPatterns.filter(isOrderSensitive)

    static func matches(_ patterns: [String]) -> Bool {
        patterns.count == FileExclusionRules.defaultPatterns.count
            && Set(patterns) == Set(FileExclusionRules.defaultPatterns)
            && patterns.filter(isOrderSensitive) == orderedRules
    }

    private static func isOrderSensitive(_ pattern: String) -> Bool {
        pattern == ".git/*" || pattern.hasPrefix("!")
    }
}

enum FSEventIndexFilter {
    struct Context: Sendable {
        let rootPaths: [String]
        let exclusionPatterns: [String]
        let activePatterns: Set<String>
        let usesKnownExclusionFastPath: Bool

        init(rootPaths: [String], exclusionPatterns: [String]) {
            self.rootPaths = rootPaths
            self.exclusionPatterns = exclusionPatterns
            activePatterns = Set(exclusionPatterns)
            usesKnownExclusionFastPath = FSEventDefaultExclusionPolicy.matches(exclusionPatterns)
        }
    }

    static func indexableEvents(
        _ events: [FileSystemEvent],
        rootPaths: [String],
        exclusionPatterns: [String]
    ) -> [FileSystemEvent] {
        indexableEvents(
            events,
            context: Context(rootPaths: rootPaths, exclusionPatterns: exclusionPatterns)
        )
    }

    static func indexableEvents(
        _ events: [FileSystemEvent],
        context: Context
    ) -> [FileSystemEvent] {
        guard !events.isEmpty else { return [] }
        let events = coalescedEventsByPath(events)
        var exclusions: FileExclusionRules?
        var filteredEvents: [FileSystemEvent] = []
        filteredEvents.reserveCapacity(events.count)

        for event in events {
            if event.requiresRecursiveRescan {
                filteredEvents.append(event)
                continue
            }
            if context.usesKnownExclusionFastPath,
               isKnownExcludedEventPath(event.path, activePatterns: context.activePatterns) {
                continue
            }
            if exclusions == nil {
                exclusions = FileExclusionRules(patterns: context.exclusionPatterns)
            }
            guard let exclusions, shouldQueue(event, rootPaths: context.rootPaths, exclusions: exclusions) else {
                continue
            }
            filteredEvents.append(event)
        }

        return filteredEvents
    }

    private static func coalescedEventsByPath(_ events: [FileSystemEvent]) -> [FileSystemEvent] {
        guard events.count > 1 else { return events }

        var coalescedEvents: [FileSystemEvent] = []
        var indexesByPath: [String: Int] = [:]
        coalescedEvents.reserveCapacity(events.count)
        indexesByPath.reserveCapacity(events.count)

        for event in events {
            if let existingIndex = indexesByPath[event.path] {
                let existing = coalescedEvents[existingIndex]
                coalescedEvents[existingIndex] = existing.merging(event)
            } else {
                indexesByPath[event.path] = coalescedEvents.count
                coalescedEvents.append(event)
            }
        }

        return coalescedEvents
    }

    static func isKnownExcludedEventPath(_ path: String, activePatterns: Set<String>) -> Bool {
        let lowerPath = path.lowercased()
        let lastComponent = lastPathComponent(in: lowerPath)

        if activePatterns.contains(".git/*"), containsComponent(".git", in: lowerPath) {
            if lowerPath.hasSuffix("/.git") {
                return false
            }
            if containsPathFragment("/.git/hooks", in: lowerPath)
                || containsPathFragment("/.git/info", in: lowerPath)
                || lowerPath.hasSuffix("/.git/config")
                || lowerPath.hasSuffix("/.git/head")
                || lowerPath.hasSuffix("/.git/description")
            {
                return false
            }
            return true
        }
        if activePatterns.contains(".hg/store/"), containsPathFragment("/.hg/store", in: lowerPath) {
            return true
        }
        if activePatterns.contains(".svn/pristine/"), containsPathFragment("/.svn/pristine", in: lowerPath) {
            return true
        }

        if activePatterns.contains("node_modules/"), containsComponent("node_modules", in: lowerPath) {
            return true
        }
        if activePatterns.contains("DerivedData/"), containsComponent("deriveddata", in: lowerPath) {
            return true
        }
        if activePatterns.contains(".gradle/caches/"), containsPathFragment("/.gradle/caches", in: lowerPath) {
            return true
        }
        if activePatterns.contains(".dart_tool/"), containsComponent(".dart_tool", in: lowerPath) {
            return true
        }
        if activePatterns.contains(".next/cache/"), containsPathFragment("/.next/cache", in: lowerPath) {
            return true
        }
        if activePatterns.contains(".parcel-cache/"), containsComponent(".parcel-cache", in: lowerPath) {
            return true
        }
        if activePatterns.contains(".turbo/"), containsComponent(".turbo", in: lowerPath) {
            return true
        }
        if activePatterns.contains(".build/**/index/store/"), lowerPath.contains("/.build/"),
           containsPathFragment("/index/store", in: lowerPath) {
            return true
        }
        if lowerPath.contains("/.build/") {
            if activePatterns.contains(".build/debug/"), containsPathFragment("/.build/debug", in: lowerPath) {
                return true
            }
            if activePatterns.contains(".build/release/"), containsPathFragment("/.build/release", in: lowerPath) {
                return true
            }
            if activePatterns.contains(".build/plugins/"), containsPathFragment("/.build/plugins", in: lowerPath) {
                return true
            }
            if activePatterns.contains(".build/artifacts/"), containsPathFragment("/.build/artifacts", in: lowerPath) {
                return true
            }
            if activePatterns.contains(".build/*/debug/"),
               containsBuildNestedDirectory("debug", in: lowerPath) {
                return true
            }
            if activePatterns.contains(".build/*/release/"),
               containsBuildNestedDirectory("release", in: lowerPath) {
                return true
            }
            if activePatterns.contains(".build/*/index/"),
               containsBuildNestedDirectory("index", in: lowerPath) {
                return true
            }
            if activePatterns.contains(".build/*/ModuleCache/"),
               containsBuildNestedDirectory("modulecache", in: lowerPath) {
                return true
            }
        }
        if activePatterns.contains("CMakeFiles/"), containsComponent("cmakefiles", in: lowerPath) {
            return true
        }
        if activePatterns.contains("Testing/Temporary/"), containsPathFragment("/testing/temporary", in: lowerPath) {
            return true
        }
        if activePatterns.contains("build/.cmake/api/"), containsPathFragment("/build/.cmake/api", in: lowerPath) {
            return true
        }
        if
            (activePatterns.contains("build/_deps/") || activePatterns.contains("build/**/_deps/")),
            lowerPath.contains("/build/"),
            containsComponent("_deps", in: lowerPath)
        {
            return true
        }
        if
            activePatterns.contains("build/**/*.tmp*"),
            lowerPath.contains("/build/"),
            lastComponent.contains(".tmp")
        {
            return true
        }
        if activePatterns.contains("*.o"), lastComponent.hasSuffix(".o") {
            return true
        }
        if activePatterns.contains("*.pyc"), lastComponent.hasSuffix(".pyc") {
            return true
        }
        if activePatterns.contains("*.pyo"), lastComponent.hasSuffix(".pyo") {
            return true
        }
        if activePatterns.contains("*.gcda"), lastComponent.hasSuffix(".gcda") {
            return true
        }
        if activePatterns.contains("*.gcno"), lastComponent.hasSuffix(".gcno") {
            return true
        }
        if activePatterns.contains("*.profraw"), lastComponent.hasSuffix(".profraw") {
            return true
        }
        if activePatterns.contains("*.profdata"), lastComponent.hasSuffix(".profdata") {
            return true
        }
        if activePatterns.contains("*.dSYM/"), lowerPath.contains(".dsym/") || lowerPath.hasSuffix(".dsym") {
            return true
        }
        if activePatterns.contains(".venv/"), containsComponent(".venv", in: lowerPath) {
            return true
        }
        if activePatterns.contains("venv/"), containsComponent("venv", in: lowerPath) {
            return true
        }
        if activePatterns.contains(".tox/"), containsComponent(".tox", in: lowerPath) {
            return true
        }
        if activePatterns.contains("__pycache__/"), containsComponent("__pycache__", in: lowerPath) {
            return true
        }
        if activePatterns.contains(".pytest_cache/"), containsComponent(".pytest_cache", in: lowerPath) {
            return true
        }
        if activePatterns.contains(".mypy_cache/"), containsComponent(".mypy_cache", in: lowerPath) {
            return true
        }
        if activePatterns.contains(".ruff_cache/"), containsComponent(".ruff_cache", in: lowerPath) {
            return true
        }
        if activePatterns.contains(".cache/"), containsComponent(".cache", in: lowerPath) {
            return true
        }
        if activePatterns.contains("Library/Caches/"), containsPathFragment("/library/caches", in: lowerPath) {
            return true
        }
        if activePatterns.contains(".Trash/"), containsComponent(".trash", in: lowerPath) {
            return true
        }

        return false
    }

    private static func lastPathComponent(in lowerPath: String) -> Substring {
        guard let slashIndex = lowerPath.lastIndex(of: "/") else {
            return Substring(lowerPath)
        }
        return lowerPath[lowerPath.index(after: slashIndex)...]
    }

    private static func containsComponent(_ component: String, in lowerPath: String) -> Bool {
        lowerPath.hasSuffix("/" + component) || lowerPath.contains("/" + component + "/")
    }

    private static func containsPathFragment(_ fragment: String, in lowerPath: String) -> Bool {
        lowerPath.contains(fragment + "/") || lowerPath.hasSuffix(fragment)
    }

    private static func containsBuildNestedDirectory(_ directory: String, in lowerPath: String) -> Bool {
        guard let buildRange = lowerPath.range(of: "/.build/") else { return false }
        let remainder = lowerPath[buildRange.upperBound...]
        let components = remainder.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: true)
        guard components.count >= 2 else { return false }
        return components[1] == Substring(directory)
    }

    private static func shouldQueue(
        _ event: FileSystemEvent,
        rootPaths: [String],
        exclusions: FileExclusionRules
    ) -> Bool {
        let url = URL(fileURLWithPath: event.path)
        if event.itemIsDirectory {
            return exclusions.decision(url: url, roots: rootPaths, isDirectory: true) != .prune
        }

        let fileDecision = exclusions.decision(url: url, roots: rootPaths, isDirectory: false)
        if fileDecision != .prune {
            return true
        }

        let directoryDecision = exclusions.decision(url: url, roots: rootPaths, isDirectory: true)
        return directoryDecision != .prune
    }
}

struct FSEventReconciliationScopeRouting: Equatable, Sendable {
    let directoryPaths: [String]
    let updatePaths: [String]

    var isEmpty: Bool {
        directoryPaths.isEmpty && updatePaths.isEmpty
    }
}

struct FSEventLiveRefreshScopeRouting: Equatable, Sendable {
    let exactPaths: [String]
    let directoryPaths: [String]
    let recursivePaths: [String]

    var isEmpty: Bool {
        exactPaths.isEmpty && directoryPaths.isEmpty
    }
}

enum FSEventLiveRefreshScopeRouter {
    static func route(events: [FileSystemEvent], rootPaths: [String]) -> FSEventLiveRefreshScopeRouting {
        let rootPaths = rootPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        var exactPaths = Set<String>()
        var directoryScopes = Set<String>()
        var recursivePaths = Set<String>()

        for event in events {
            let path = URL(fileURLWithPath: event.path).standardizedFileURL.path
            if event.invalidatesEntireStream {
                directoryScopes.formUnion(rootPaths)
                recursivePaths.formUnion(rootPaths)
                continue
            }

            guard pathIsWithinRoots(path, rootPaths: rootPaths) else {
                if event.requiresRecursiveRescan {
                    directoryScopes.formUnion(rootPaths)
                    recursivePaths.formUnion(rootPaths)
                }
                continue
            }

            if event.requiresDirectoryRefreshScope {
                let scope = directoryScope(for: event, standardizedPath: path, rootPaths: rootPaths)
                directoryScopes.insert(scope)
                if event.requiresRecursiveRescan {
                    recursivePaths.insert(scope)
                }
            } else {
                exactPaths.insert(path)
            }
        }

        if !directoryScopes.isEmpty {
            exactPaths = exactPaths.filter { exactPath in
                directoryScopes.contains { scope in
                    exactPath == scope || exactPath.hasPrefix(scope + "/")
                } == false
            }
        }

        return FSEventLiveRefreshScopeRouting(
            exactPaths: exactPaths.sorted(),
            directoryPaths: collapsedPaths(directoryScopes),
            recursivePaths: recursivePaths.sorted()
        )
    }

    private static func pathIsWithinRoots(_ path: String, rootPaths: [String]) -> Bool {
        rootPaths.contains { pathIsWithinRoot(path, root: $0) }
    }

    private static func directoryScope(
        for event: FileSystemEvent,
        standardizedPath: String,
        rootPaths: [String]
    ) -> String {
        guard let root = rootPaths.first(where: { pathIsWithinRoot(standardizedPath, root: $0) }) else {
            return standardizedPath
        }
        guard standardizedPath != root else { return root }
        if event.itemIsDirectory {
            return standardizedPath
        }

        let parent = URL(fileURLWithPath: standardizedPath).deletingLastPathComponent().standardizedFileURL.path
        guard pathIsWithinRoot(parent, root: root) else {
            return root
        }
        return parent
    }

    private static func pathIsWithinRoot(_ path: String, root: String) -> Bool {
        root == "/" || path == root || path.hasPrefix(root + "/")
    }

    private static func collapsedPaths(_ paths: Set<String>) -> [String] {
        var collapsed: [String] = []
        for path in paths.sorted(by: { $0.count < $1.count }) {
            guard !collapsed.contains(where: { pathIsWithinRoot(path, root: $0) }) else {
                continue
            }
            collapsed.append(path)
        }
        return collapsed
    }
}

enum FSEventReconciliationScopeRouter {
    static func route(paths: [String], fileManager: FileManager = .default) -> FSEventReconciliationScopeRouting {
        route(paths: paths) { path in
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return false
            }
            return isDirectory.boolValue
        }
    }

    static func route(paths: [String], isDirectory: (String) -> Bool) -> FSEventReconciliationScopeRouting {
        var seen = Set<String>()
        var directoryPaths: [String] = []
        var updatePaths: [String] = []

        for rawPath in paths {
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            if isDirectory(path) {
                directoryPaths.append(path)
            } else {
                updatePaths.append(path)
            }
        }

        if !directoryPaths.isEmpty && !updatePaths.isEmpty {
            updatePaths.removeAll { updatePath in
                directoryPaths.contains { directoryPath in
                    updatePath == directoryPath || updatePath.hasPrefix(directoryPath + "/")
                }
            }
        }

        return FSEventReconciliationScopeRouting(
            directoryPaths: directoryPaths,
            updatePaths: updatePaths
        )
    }
}

final class FileSystemWatcher {
    struct StreamConfiguration: Equatable, Sendable {
        static let interactive = StreamConfiguration(latency: 0.05, usesNoDefer: true)
        static let background = StreamConfiguration(latency: 3.0, usesNoDefer: false)

        let latency: TimeInterval
        let usesNoDefer: Bool

        var flags: UInt32 {
            var flags = UInt32(kFSEventStreamCreateFlagUseCFTypes)
                | UInt32(kFSEventStreamCreateFlagFileEvents)
                | UInt32(kFSEventStreamCreateFlagWatchRoot)
            if usesNoDefer {
                flags |= UInt32(kFSEventStreamCreateFlagNoDefer)
            }
            return flags
        }
    }

    private let queue = DispatchQueue(label: "att.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?
    private var eventHandler: (@MainActor @Sendable ([FileSystemEvent]) -> Void)?
    private var rootPaths: [String] = []
    private var streamConfiguration: StreamConfiguration?

    deinit {
        stop()
    }

    func start(
        roots: [URL],
        configuration: StreamConfiguration = .interactive,
        eventHandler: @escaping @MainActor @Sendable ([FileSystemEvent]) -> Void
    ) {
        let paths = roots.map { $0.standardizedFileURL.path }
        guard !paths.isEmpty else { return }

        if stream != nil, paths == rootPaths, configuration == streamConfiguration {
            self.eventHandler = eventHandler
            return
        }

        stop()

        self.eventHandler = eventHandler
        self.rootPaths = paths
        self.streamConfiguration = configuration

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, eventIDs in
            guard let info else { return }
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let flags = UnsafeBufferPointer(start: eventFlags, count: eventCount)
            let ids = UnsafeBufferPointer(start: eventIDs, count: eventCount)
            let events = paths.prefix(eventCount).enumerated().map { offset, path in
                FileSystemEvent(path: path, flags: flags[offset], eventID: ids[offset])
            }
            watcher.handle(events: events)
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            configuration.latency,
            configuration.flags
        )

        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            rootPaths = []
            streamConfiguration = nil
        }
    }

    private func handle(events: [FileSystemEvent]) {
        guard !events.isEmpty else { return }
        guard let eventHandler else { return }

        Task { @MainActor in
            eventHandler(events)
        }
    }
}

protocol FSEventHistoryReplayCancellable: AnyObject, Sendable {
    func cancel()
}

enum FSEventHistoryReplayCompletion: Sendable, Equatable {
    case completed
    case failed
    case timedOut
}

protocol FSEventHistoryReplaySource: AnyObject, Sendable {
    @discardableResult
    func replay(
        roots: [URL],
        sinceEventID: FSEventStreamEventId,
        timeout: TimeInterval,
        eventHandler: @escaping @Sendable ([FileSystemEvent]) -> Void,
        completion: @escaping @Sendable (FSEventHistoryReplayCompletion) -> Void
    ) -> FSEventHistoryReplayCancellable?
}

final class FSEventStreamHistoryReplaySource: FSEventHistoryReplaySource {
    func replay(
        roots: [URL],
        sinceEventID: FSEventStreamEventId,
        timeout: TimeInterval = 30,
        eventHandler: @escaping @Sendable ([FileSystemEvent]) -> Void,
        completion: @escaping @Sendable (FSEventHistoryReplayCompletion) -> Void
    ) -> FSEventHistoryReplayCancellable? {
        let session = FSEventHistoryReplaySession(
            roots: roots,
            sinceEventID: sinceEventID,
            timeout: timeout,
            eventHandler: eventHandler,
            completion: completion
        )
        guard session.start() else { return nil }
        return session
    }
}

enum FSEventReconciliationAction: Equatable, Sendable {
    case reconcile(paths: [String], baselineEventID: UInt64)
    case upToDate(baselineEventID: UInt64)
    case fullReconcile(paths: [String]?, baselineEventID: UInt64)
}

final class FSEventReconciliationCoordinator: @unchecked Sendable {
    private let cursorStore: FSEventCursorStore
    private let replaySource: FSEventHistoryReplaySource
    private let timeout: TimeInterval
    private let currentEventID: @Sendable () -> UInt64

    init(
        cursorStore: FSEventCursorStore = .default,
        replaySource: FSEventHistoryReplaySource = FSEventStreamHistoryReplaySource(),
        timeout: TimeInterval = 30,
        currentEventID: @escaping @Sendable () -> UInt64 = { UInt64(FSEventsGetCurrentEventId()) }
    ) {
        self.cursorStore = cursorStore
        self.replaySource = replaySource
        self.timeout = timeout
        self.currentEventID = currentEventID
    }

    @discardableResult
    func reconcile(
        roots: [URL],
        exclusions: FileExclusionRules = FileExclusionRules(),
        completion: @escaping @MainActor @Sendable (FSEventReconciliationAction) -> Void
    ) -> FSEventHistoryReplayCancellable? {
        let rootPaths = roots.map { $0.standardizedFileURL.path }
        guard !rootPaths.isEmpty else {
            Task { @MainActor in completion(.upToDate(baselineEventID: currentEventID())) }
            return nil
        }

        let cursors = cursorStore.eventIDs(for: rootPaths)
        guard cursors.count == rootPaths.count, let sinceEventID = cursors.values.min(), sinceEventID > 0 else {
            let baselineEventID = currentEventID()
            Task { @MainActor in
                completion(.fullReconcile(paths: nil, baselineEventID: baselineEventID))
            }
            return nil
        }

        let collector = FSEventHistoryReplayCollector(
            rootPaths: rootPaths,
            exclusions: exclusions,
            baselineEventID: sinceEventID
        )
        guard let session = replaySource.replay(
            roots: roots,
            sinceEventID: FSEventStreamEventId(sinceEventID),
            timeout: timeout,
            eventHandler: { [cursorStore] events in
                if events.contains(where: \.eventIDsWrapped) {
                    cursorStore.invalidate(roots: rootPaths)
                }
                collector.ingest(events)
            },
            completion: { [currentEventID] result in
                let action = collector.action(completion: result, currentEventID: currentEventID())
                Task { @MainActor in
                    completion(action)
                }
            }
        ) else {
            let baselineEventID = currentEventID()
            Task { @MainActor in
                completion(.fullReconcile(paths: nil, baselineEventID: baselineEventID))
            }
            return nil
        }

        return session
    }
}

private final class FSEventHistoryReplayCollector: @unchecked Sendable {
    private static let maximumHistoricalReconciliationPaths = 5_000

    private let rootPaths: [String]
    private let exclusions: FileExclusionRules
    private let activeExclusionPatterns: Set<String>
    private let usesKnownExclusionFastPath: Bool
    private let lock = NSLock()
    private var reconciliationPaths = Set<String>()
    private var fallbackRootPaths = Set<String>()
    private var requiresGlobalFallback = false
    private var invalidatedEntireStream = false
    private var sawHistoryDone = false
    private var replayBaselineEventID: UInt64
    private var rawEventCount = 0
    private var droppedExcludedEventCount = 0

    init(rootPaths: [String], exclusions: FileExclusionRules, baselineEventID: UInt64) {
        self.rootPaths = rootPaths.sorted { $0.count > $1.count }
        self.exclusions = exclusions
        replayBaselineEventID = baselineEventID
        activeExclusionPatterns = Set(exclusions.patterns)
        usesKnownExclusionFastPath = FSEventDefaultExclusionPolicy.matches(exclusions.patterns)
    }

    func ingest(_ events: [FileSystemEvent]) {
        lock.lock()
        defer { lock.unlock() }

        rawEventCount += events.count

        for event in events {
            replayBaselineEventID = max(replayBaselineEventID, UInt64(event.eventID))
            if event.historyReplayCompleted {
                sawHistoryDone = true
                if !event.historyIsUnsafe {
                    continue
                }
            }

            if event.invalidatesEntireStream {
                invalidatedEntireStream = true
                fallbackRootPaths.formUnion(rootPaths)
                continue
            }

            guard let rootPath = matchingRoot(for: event.path) else {
                requiresGlobalFallback = true
                continue
            }

            if event.requiresRecursiveRescan {
                fallbackRootPaths.insert(rootPath)
                continue
            }

            if usesKnownExclusionFastPath,
               FSEventIndexFilter.isKnownExcludedEventPath(event.path, activePatterns: activeExclusionPatterns) {
                droppedExcludedEventCount += 1
                continue
            }

            let decision = exclusionDecision(for: event)
            guard decision != .prune else {
                droppedExcludedEventCount += 1
                continue
            }

            reconciliationPaths.insert(reconciliationScope(for: event, rootPath: rootPath, decision: decision))

            if requiresGlobalFallback {
                continue
            }

            guard reconciliationPaths.count < Self.maximumHistoricalReconciliationPaths else {
                let collapsedParentScopes = Set(reconciliationPaths.map {
                    parentScope(for: $0, rootPath: matchingRoot(for: $0) ?? rootPath)
                })
                let collapsedPaths = Set(Self.collapsedPaths(collapsedParentScopes))
                if collapsedPaths.count < Self.maximumHistoricalReconciliationPaths {
                    reconciliationPaths = collapsedPaths
                } else {
                    reconciliationPaths.removeAll(keepingCapacity: false)
                    requiresGlobalFallback = true
                }
                continue
            }
        }
    }

    func action(completion: FSEventHistoryReplayCompletion, currentEventID: UInt64) -> FSEventReconciliationAction {
        lock.lock()
        let action: FSEventReconciliationAction
        let collapsedScopeCount: Int
        let keptScopeCount = reconciliationPaths.count + fallbackRootPaths.count
        let loggedRawEventCount = rawEventCount
        let loggedDroppedExcludedEventCount = droppedExcludedEventCount
        let loggedRequiresGlobalFallback = requiresGlobalFallback

        if completion != .completed || !sawHistoryDone {
            action = .fullReconcile(paths: nil, baselineEventID: currentEventID)
            collapsedScopeCount = 0
        } else if requiresGlobalFallback {
            action = .fullReconcile(paths: nil, baselineEventID: currentEventID)
            collapsedScopeCount = 0
        } else if !fallbackRootPaths.isEmpty {
            let paths = Self.collapsedPaths(fallbackRootPaths.union(reconciliationPaths))
            let baselineEventID = invalidatedEntireStream ? currentEventID : replayBaselineEventID
            action = .fullReconcile(paths: paths, baselineEventID: baselineEventID)
            collapsedScopeCount = paths.count
        } else if reconciliationPaths.isEmpty {
            action = .upToDate(baselineEventID: replayBaselineEventID)
            collapsedScopeCount = 0
        } else {
            let paths = Self.collapsedPaths(reconciliationPaths)
            action = .reconcile(paths: paths, baselineEventID: replayBaselineEventID)
            collapsedScopeCount = paths.count
        }
        lock.unlock()

        DiagnosticLogger.shared.log(
            category: "fsevents",
            event: "fsevents.reconciliationFiltered",
            fields: [
                "rawEventCount": .publicInt(loggedRawEventCount),
                "droppedExcludedEventCount": .publicInt(loggedDroppedExcludedEventCount),
                "keptScopeCount": .publicInt(keptScopeCount),
                "collapsedScopeCount": .publicInt(collapsedScopeCount),
                "requiresGlobalFallback": .publicBool(loggedRequiresGlobalFallback)
            ]
        )

        return action
    }

    private func matchingRoot(for path: String) -> String? {
        rootPaths.first { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func exclusionDecision(for event: FileSystemEvent) -> FileExclusionRules.Decision {
        let url = URL(fileURLWithPath: event.path).standardizedFileURL
        let decision = exclusions.decision(url: url, roots: rootPaths, isDirectory: event.itemIsDirectory)
        guard decision == .prune, !event.itemIsDirectory else { return decision }

        let directoryDecision = exclusions.decision(url: url, roots: rootPaths, isDirectory: true)
        return directoryDecision == .index ? directoryDecision : decision
    }

    private func reconciliationScope(
        for event: FileSystemEvent,
        rootPath: String,
        decision: FileExclusionRules.Decision
    ) -> String {
        let path = URL(fileURLWithPath: event.path).standardizedFileURL.path
        guard path != rootPath else { return rootPath }

        if event.itemIsDirectory || decision == .skipButDescend {
            return path
        }

        if event.requiresRecursiveRescan || event.itemChangeRequiresDirectoryScope {
            return parentScope(for: path, rootPath: rootPath)
        }

        return path
    }

    private func parentScope(for path: String, rootPath: String) -> String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
        guard parent != "/", parent == rootPath || parent.hasPrefix(rootPath + "/") else {
            return rootPath
        }
        return parent
    }

    private static func collapsedPaths(_ paths: Set<String>) -> [String] {
        var collapsed: [String] = []
        for path in paths.sorted(by: { $0.count < $1.count }) {
            guard !collapsed.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
                continue
            }
            collapsed.append(path)
        }
        return collapsed
    }
}

private final class FSEventHistoryReplaySession: FSEventHistoryReplayCancellable, @unchecked Sendable {
    private let queue = DispatchQueue(label: "att.fsevents.history", qos: .utility)
    private let roots: [URL]
    private let sinceEventID: FSEventStreamEventId
    private let timeout: TimeInterval
    private let eventHandler: @Sendable ([FileSystemEvent]) -> Void
    private let completion: @Sendable (FSEventHistoryReplayCompletion) -> Void
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var didFinish = false

    init(
        roots: [URL],
        sinceEventID: FSEventStreamEventId,
        timeout: TimeInterval,
        eventHandler: @escaping @Sendable ([FileSystemEvent]) -> Void,
        completion: @escaping @Sendable (FSEventHistoryReplayCompletion) -> Void
    ) {
        self.roots = roots
        self.sinceEventID = sinceEventID
        self.timeout = timeout
        self.eventHandler = eventHandler
        self.completion = completion
    }

    deinit {
        cancel()
    }

    func start() -> Bool {
        let paths = roots.map { $0.standardizedFileURL.path }
        guard !paths.isEmpty else { return false }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, eventIDs in
            guard let info else { return }
            let session = Unmanaged<FSEventHistoryReplaySession>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let flags = UnsafeBufferPointer(start: eventFlags, count: eventCount)
            let ids = UnsafeBufferPointer(start: eventIDs, count: eventCount)
            let events = paths.prefix(eventCount).enumerated().map { offset, path in
                FileSystemEvent(path: path, flags: flags[offset], eventID: ids[offset])
            }
            session.handle(events)
        }

        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes)
            | UInt32(kFSEventStreamCreateFlagFileEvents)
            | UInt32(kFSEventStreamCreateFlagNoDefer)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            sinceEventID,
            0.05,
            flags
        ) else {
            return false
        }

        lock.lock()
        self.stream = stream
        lock.unlock()

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            finish(.failed, notifiesCompletion: false)
            return false
        }

        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.timedOut)
        }

        return true
    }

    func cancel() {
        finish(.failed, notifiesCompletion: false)
    }

    private func handle(_ events: [FileSystemEvent]) {
        guard !events.isEmpty else { return }
        eventHandler(events)
        if events.contains(where: \.historyReplayCompleted) {
            finish(.completed)
        }
    }

    private func finish(_ result: FSEventHistoryReplayCompletion, notifiesCompletion: Bool = true) {
        let streamToClose: FSEventStreamRef?
        lock.lock()
        if didFinish {
            lock.unlock()
            return
        }
        didFinish = true
        streamToClose = stream
        stream = nil
        lock.unlock()

        if let streamToClose {
            FSEventStreamStop(streamToClose)
            FSEventStreamInvalidate(streamToClose)
            FSEventStreamRelease(streamToClose)
        }

        if notifiesCompletion {
            completion(result)
        }
    }
}

final class FSEventCursorStore: @unchecked Sendable {
    static let `default` = FSEventCursorStore(url: defaultURL())

    private let url: URL
    private let fileManager: FileManager
    private let deferredUpdateInterval: TimeInterval
    private let saveQueue = DispatchQueue(label: "att.fsevents.cursor-save", qos: .utility)
    private let lock = NSLock()
    private var pendingUpdates: [String: UInt64] = [:]
    private var pendingSave: DispatchWorkItem?

    init(
        url: URL,
        fileManager: FileManager = .default,
        deferredUpdateInterval: TimeInterval = 30
    ) {
        self.url = url
        self.fileManager = fileManager
        self.deferredUpdateInterval = deferredUpdateInterval
    }

    deinit {
        flushPendingUpdates()
    }

    func eventID(for root: String) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        let key = key(for: root)
        let persisted = load()[key]
        let pending = pendingUpdates[key]
        guard persisted != nil || pending != nil else { return nil }
        return max(persisted ?? 0, pending ?? 0)
    }

    func eventIDs(for roots: [String]) -> [String: UInt64] {
        lock.lock()
        defer { lock.unlock() }

        let cursors = load()
        var result: [String: UInt64] = [:]
        for root in roots {
            let key = key(for: root)
            let persisted = cursors[key]
            let pending = pendingUpdates[key]
            guard persisted != nil || pending != nil else { continue }
            result[root] = max(persisted ?? 0, pending ?? 0)
        }
        return result
    }

    func update(_ latestByRoot: [String: UInt64]) {
        guard !latestByRoot.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        pendingSave?.cancel()
        pendingSave = nil
        var cursors = load()
        merge(pendingUpdates, into: &cursors)
        pendingUpdates.removeAll(keepingCapacity: true)
        for (root, eventID) in latestByRoot {
            let key = key(for: root)
            cursors[key] = max(cursors[key] ?? 0, eventID)
        }
        save(cursors)
    }

    func updateDeferred(_ latestByRoot: [String: UInt64]) {
        guard !latestByRoot.isEmpty else { return }

        lock.lock()
        for (root, eventID) in latestByRoot {
            let key = key(for: root)
            pendingUpdates[key] = max(pendingUpdates[key] ?? 0, eventID)
        }
        guard !pendingUpdates.isEmpty else {
            lock.unlock()
            return
        }
        guard pendingSave == nil else {
            lock.unlock()
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPendingUpdates()
        }
        pendingSave = workItem
        lock.unlock()
        saveQueue.asyncAfter(deadline: .now() + deferredUpdateInterval, execute: workItem)
    }

    func flushPendingUpdates() {
        lock.lock()
        defer { lock.unlock() }

        pendingSave?.cancel()
        pendingSave = nil
        guard !pendingUpdates.isEmpty else { return }

        var cursors = load()
        merge(pendingUpdates, into: &cursors)
        pendingUpdates.removeAll(keepingCapacity: true)
        save(cursors)
    }

    func markBaseline(for roots: [String], eventID: UInt64 = UInt64(FSEventsGetCurrentEventId())) {
        let baselines = Dictionary(uniqueKeysWithValues: roots.map { ($0, eventID) })
        update(baselines)
    }

    func invalidate(roots: [String]) {
        guard !roots.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        pendingSave?.cancel()
        pendingSave = nil
        var cursors = load()
        for root in roots {
            let key = key(for: root)
            cursors.removeValue(forKey: key)
            pendingUpdates.removeValue(forKey: key)
        }
        save(cursors)
    }

    private func merge(_ updates: [String: UInt64], into cursors: inout [String: UInt64]) {
        for (key, eventID) in updates {
            cursors[key] = max(cursors[key] ?? 0, eventID)
        }
    }

    private func load() -> [String: UInt64] {
        guard
            let data = try? Data(contentsOf: url),
            let cursors = try? JSONDecoder().decode([String: UInt64].self, from: data)
        else {
            return [:]
        }
        return cursors
    }

    private func save(_ cursors: [String: UInt64]) {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(cursors)
            try data.write(to: url, options: .atomic)
        } catch {
            // FSEvents will fall back to current events if the cursor sidecar cannot be written.
        }
    }

    private func key(for root: String) -> String {
        "root-\(FileRecordStableHash.hash(root))"
    }

    private static func defaultURL() -> URL {
        let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return supportRoot
            .appendingPathComponent("AllTheThings", isDirectory: true)
            .appendingPathComponent("fsevents-cursors.json", isDirectory: false)
    }
}

private enum FileRecordStableHash {
    static func hash(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}
