import CoreServices
@_spi(ATTInternal) import ATTCore
import Foundation

struct FileSystemEvent: Sendable {
    let path: String
    let flags: FSEventStreamEventFlags
    let eventID: FSEventStreamEventId

    init(path: String, flags: FSEventStreamEventFlags, eventID: FSEventStreamEventId) {
        // FSEvents supplies canonical paths. Synthetic events used by repair and tests
        // occasionally do not, so normalize those exceptional cases once at ingress.
        if Self.requiresPathNormalization(path) {
            self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        } else {
            self.path = path
        }
        self.flags = flags
        self.eventID = eventID
    }

    private static func requiresPathNormalization(_ path: String) -> Bool {
        (path.count > 1 && path.hasSuffix("/"))
            || path.contains("//")
            || path.contains("/./")
            || path.contains("/../")
            || path.hasSuffix("/.")
            || path.hasSuffix("/..")
    }

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

struct FSEventRootMatcher {
    private struct Root {
        let path: String
        let descendantPrefix: String
    }

    let rootPaths: [String]
    private let roots: [Root]

    init(rootPaths: [String]) {
        let standardizedRoots = rootPaths.enumerated().map { offset, path in
            (offset: offset, path: URL(fileURLWithPath: path).standardizedFileURL.path)
        }
        let orderedRoots = standardizedRoots.sorted { lhs, rhs in
            if lhs.path.count != rhs.path.count {
                return lhs.path.count > rhs.path.count
            }
            return lhs.offset < rhs.offset
        }
        self.rootPaths = orderedRoots.map(\.path)
        roots = self.rootPaths.map { rootPath in
            Root(
                path: rootPath,
                descendantPrefix: rootPath == "/" ? "/" : rootPath + "/"
            )
        }
    }

    func matchingRoot(for path: String) -> String? {
        roots.first { root in
            root.path == "/" || path == root.path || path.hasPrefix(root.descendantPrefix)
        }?.path
    }
}

enum FSEventCursorAdvances {
    static func latestByRoot(
        events: [FileSystemEvent],
        rootPaths: [String],
        wrappedBaselineEventID: UInt64? = nil
    ) -> [String: UInt64] {
        guard !events.isEmpty, !rootPaths.isEmpty else { return [:] }

        let rootMatcher = FSEventRootMatcher(rootPaths: rootPaths)
        if
            let wrappedBaselineEventID,
            events.contains(where: \.eventIDsWrapped)
        {
            return Dictionary(uniqueKeysWithValues: rootMatcher.rootPaths.map { ($0, wrappedBaselineEventID) })
        }

        var latestByRoot: [String: UInt64] = [:]
        for event in events {
            if event.historyIsUnsafe {
                for root in rootMatcher.rootPaths {
                    latestByRoot[root] = max(latestByRoot[root] ?? 0, UInt64(event.eventID))
                }
                continue
            }

            guard let root = rootMatcher.matchingRoot(for: event.path) else {
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
            && Array(patterns.prefix(orderedRules.count)) == orderedRules
    }

    private static func isOrderSensitive(_ pattern: String) -> Bool {
        pattern == ".git/*" || pattern.hasPrefix("!")
    }
}

enum FSEventIndexFilter {
    struct Instrumentation: Equatable, Sendable {
        var defaultFastPathDecisionCount = 0
        var compiledQueryBuildCount = 0
        var compiledDecisionCount = 0
        var redundantCoalescingEventCountAvoided = 0
    }

    struct Context: Sendable {
        let rootPaths: [String]
        let exclusionPatterns: [String]
        let activePatterns: Set<String>
        let usesKnownExclusionFastPath: Bool
        let eventsArePreCoalesced: Bool

        init(
            rootPaths: [String],
            exclusionPatterns: [String],
            eventsArePreCoalesced: Bool = false
        ) {
            self.rootPaths = rootPaths
            self.exclusionPatterns = exclusionPatterns
            self.eventsArePreCoalesced = eventsArePreCoalesced
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
        var instrumentation = Instrumentation()
        return indexableEvents(events, context: context, instrumentation: &instrumentation)
    }

    static func indexableEvents(
        _ events: [FileSystemEvent],
        context: Context,
        instrumentation: inout Instrumentation
    ) -> [FileSystemEvent] {
        guard !events.isEmpty else { return [] }
        let candidateEvents: [FileSystemEvent]
        if context.eventsArePreCoalesced {
            instrumentation.redundantCoalescingEventCountAvoided += events.count
            candidateEvents = events
        } else {
            candidateEvents = coalescedEventsByPath(events)
        }
        var exclusionDecision: ((String, Bool) -> FileExclusionRules.Decision)?
        var filteredEvents: [FileSystemEvent] = []
        filteredEvents.reserveCapacity(candidateEvents.count)

        for event in candidateEvents {
            if event.requiresRecursiveRescan {
                filteredEvents.append(event)
                continue
            }
            if context.usesKnownExclusionFastPath {
                instrumentation.defaultFastPathDecisionCount += 1
                if isKnownExcludedEventPath(
                    event.path,
                    activePatterns: context.activePatterns,
                    isDirectory: event.itemIsDirectory
                ) {
                    continue
                }
                filteredEvents.append(event)
                continue
            }
            if exclusionDecision == nil {
                exclusionDecision = FileExclusionRules(patterns: context.exclusionPatterns)
                    .makeDecisionEvaluator(roots: context.rootPaths)
                instrumentation.compiledQueryBuildCount += 1
            }
            guard let exclusionDecision, shouldQueue(
                event,
                exclusionDecision: exclusionDecision,
                instrumentation: &instrumentation
            ) else {
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

    static func isKnownExcludedEventPath(
        _ path: String,
        activePatterns: Set<String>,
        isDirectory: Bool = false
    ) -> Bool {
        let lowerPath = path.lowercased()
        let lastComponent = lastPathComponent(in: lowerPath)

        if activePatterns.contains(".git/*"), containsComponent(".git", in: lowerPath) {
            let isReincluded = lowerPath.hasSuffix("/.git")
                || containsPathFragment("/.git/hooks", in: lowerPath)
                || containsPathFragment("/.git/info", in: lowerPath)
                || lowerPath.hasSuffix("/.git/config")
                || lowerPath.hasSuffix("/.git/head")
                || lowerPath.hasSuffix("/.git/description")
            if !isReincluded {
                return true
            }
        }
        if activePatterns.contains(".hg/store/"),
           containsDirectoryPathFragment("/.hg/store", in: lowerPath, isDirectory: isDirectory) {
            return true
        }
        if activePatterns.contains(".svn/pristine/"),
           containsDirectoryPathFragment("/.svn/pristine", in: lowerPath, isDirectory: isDirectory) {
            return true
        }

        if activePatterns.contains("node_modules/"),
           containsDirectoryComponent("node_modules", in: lowerPath, isDirectory: isDirectory) {
            return true
        }
        if activePatterns.contains("DerivedData/"),
           containsDirectoryComponent("deriveddata", in: lowerPath, isDirectory: isDirectory) {
            return true
        }
        if activePatterns.contains(".gradle/caches/"),
           containsDirectoryPathFragment("/.gradle/caches", in: lowerPath, isDirectory: isDirectory) {
            return true
        }
        if activePatterns.contains(".dart_tool/"),
           containsDirectoryComponent(".dart_tool", in: lowerPath, isDirectory: isDirectory) {
            return true
        }
        if activePatterns.contains(".next/cache/"),
           containsDirectoryPathFragment("/.next/cache", in: lowerPath, isDirectory: isDirectory) {
            return true
        }
        if activePatterns.contains(".parcel-cache/"),
           containsDirectoryComponent(".parcel-cache", in: lowerPath, isDirectory: isDirectory) {
            return true
        }
        if activePatterns.contains(".turbo/"),
           containsDirectoryComponent(".turbo", in: lowerPath, isDirectory: isDirectory) {
            return true
        }
        if activePatterns.contains("*.app/Contents/_CodeSignature/"),
           containsDirectoryPathFragment(
               ".app/contents/_codesignature",
               in: lowerPath,
               isDirectory: isDirectory
           ) {
            return true
        }
        if activePatterns.contains("Xcode.app/Contents/Developer/Platforms/"),
           containsDirectoryPathFragment(
               "/xcode.app/contents/developer/platforms",
               in: lowerPath,
               isDirectory: isDirectory
           ) {
            return true
        }
        if activePatterns.contains("Xcode.app/Contents/Developer/Toolchains/"),
           containsDirectoryPathFragment(
               "/xcode.app/contents/developer/toolchains",
               in: lowerPath,
               isDirectory: isDirectory
           ) {
            return true
        }
        if activePatterns.contains("Engine/Binaries/ThirdParty/DotNet/"),
           containsDirectoryPathFragment(
               "/engine/binaries/thirdparty/dotnet",
               in: lowerPath,
               isDirectory: isDirectory
           ) {
            return true
        }
        if activePatterns.contains("Engine/Binaries/ThirdParty/Python3/"),
           containsDirectoryPathFragment(
               "/engine/binaries/thirdparty/python3",
               in: lowerPath,
               isDirectory: isDirectory
           ) {
            return true
        }
        if activePatterns.contains("Engine/DerivedDataCache/"),
           containsDirectoryPathFragment(
               "/engine/deriveddatacache",
               in: lowerPath,
               isDirectory: isDirectory
           ) {
            return true
        }
        if activePatterns.contains("Engine/Intermediate/"),
           containsDirectoryPathFragment(
               "/engine/intermediate",
               in: lowerPath,
               isDirectory: isDirectory
           ) {
            return true
        }
        if activePatterns.contains("Engine/Saved/"),
           containsDirectoryPathFragment("/engine/saved", in: lowerPath, isDirectory: isDirectory) {
            return true
        }
        if lowerPath.contains("/.build/") {
            if activePatterns.contains(".build/**/index/store/"),
               containsNestedBuildIndexStore(in: lowerPath, isDirectory: isDirectory) {
                return true
            }
            if activePatterns.contains(".build/debug/"),
               containsDirectoryPathFragment("/.build/debug", in: lowerPath, isDirectory: isDirectory) {
                return true
            }
            if activePatterns.contains(".build/release/"),
               containsDirectoryPathFragment("/.build/release", in: lowerPath, isDirectory: isDirectory) {
                return true
            }
            if activePatterns.contains(".build/plugins/"),
               containsDirectoryPathFragment("/.build/plugins", in: lowerPath, isDirectory: isDirectory) {
                return true
            }
            if activePatterns.contains(".build/artifacts/"),
               containsDirectoryPathFragment("/.build/artifacts", in: lowerPath, isDirectory: isDirectory) {
                return true
            }
            if activePatterns.contains(".build/*/debug/"),
               containsBuildNestedDirectory("debug", in: lowerPath, isDirectory: isDirectory) {
                return true
            }
            if activePatterns.contains(".build/*/release/"),
               containsBuildNestedDirectory("release", in: lowerPath, isDirectory: isDirectory) {
                return true
            }
            if activePatterns.contains(".build/*/index/"),
               containsBuildNestedDirectory("index", in: lowerPath, isDirectory: isDirectory) {
                return true
            }
            if activePatterns.contains(".build/*/ModuleCache/"),
               containsBuildNestedDirectory("modulecache", in: lowerPath, isDirectory: isDirectory) {
                return true
            }
        }
        if activePatterns.contains("CMakeFiles/"),
           containsDirectoryComponent("cmakefiles", in: lowerPath, isDirectory: isDirectory) {
            return true
        }
        if activePatterns.contains("Testing/Temporary/"),
           containsDirectoryPathFragment("/testing/temporary", in: lowerPath, isDirectory: isDirectory) {
            return true
        }
        if activePatterns.contains("buck-out/"),
           containsDirectoryComponent("buck-out", in: lowerPath, isDirectory: isDirectory) {
            return true
        }
        if activePatterns.contains("bazel-out/"),
           containsDirectoryComponent("bazel-out", in: lowerPath, isDirectory: isDirectory) {
            return true
        }
        if activePatterns.contains(".buckd/"),
           containsDirectoryComponent(".buckd", in: lowerPath, isDirectory: isDirectory) {
            return true
        }
        if activePatterns.contains("build/.cmake/api/"),
           containsDirectoryPathFragment("/build/.cmake/api", in: lowerPath, isDirectory: isDirectory) {
            return true
        }
        if
            (activePatterns.contains("build/_deps/") || activePatterns.contains("build/**/_deps/")),
            containsBuildDependencyDirectory(in: lowerPath, isDirectory: isDirectory)
        {
            return true
        }
        if
            activePatterns.contains("build/**/*.tmp*"),
            lastComponent.contains(".tmp"),
            containsNestedBuildTemporary(in: lowerPath)
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
        if activePatterns.contains("*.dSYM/"),
           lowerPath.contains(".dsym/") || (isDirectory && lowerPath.hasSuffix(".dsym")) {
            return true
        }
        if activePatterns.contains(".venv/"),
           containsDirectoryComponent(".venv", in: lowerPath, isDirectory: isDirectory) {
            return true
        }
        if activePatterns.contains("venv/"),
           containsDirectoryComponent("venv", in: lowerPath, isDirectory: isDirectory) {
            return true
        }
        if activePatterns.contains(".tox/"),
           containsDirectoryComponent(".tox", in: lowerPath, isDirectory: isDirectory) {
            return true
        }
        if activePatterns.contains("__pycache__/"),
           containsDirectoryComponent("__pycache__", in: lowerPath, isDirectory: isDirectory) {
            return true
        }
        if activePatterns.contains(".pytest_cache/"),
           containsDirectoryComponent(".pytest_cache", in: lowerPath, isDirectory: isDirectory) {
            return true
        }
        if activePatterns.contains(".mypy_cache/"),
           containsDirectoryComponent(".mypy_cache", in: lowerPath, isDirectory: isDirectory) {
            return true
        }
        if activePatterns.contains(".ruff_cache/"),
           containsDirectoryComponent(".ruff_cache", in: lowerPath, isDirectory: isDirectory) {
            return true
        }
        if activePatterns.contains(".cache/"),
           containsDirectoryComponent(".cache", in: lowerPath, isDirectory: isDirectory) {
            return true
        }
        if activePatterns.contains("Library/Caches/"),
           containsDirectoryPathFragment("/library/caches", in: lowerPath, isDirectory: isDirectory) {
            return true
        }
        if activePatterns.contains(".Trash/"),
           containsDirectoryComponent(".trash", in: lowerPath, isDirectory: isDirectory) {
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

    private static func containsDirectoryComponent(
        _ component: String,
        in lowerPath: String,
        isDirectory: Bool
    ) -> Bool {
        lowerPath.contains("/" + component + "/")
            || (isDirectory && lowerPath.hasSuffix("/" + component))
    }

    private static func containsPathFragment(_ fragment: String, in lowerPath: String) -> Bool {
        lowerPath.contains(fragment + "/") || lowerPath.hasSuffix(fragment)
    }

    private static func containsDirectoryPathFragment(
        _ fragment: String,
        in lowerPath: String,
        isDirectory: Bool
    ) -> Bool {
        lowerPath.contains(fragment + "/")
            || (isDirectory && lowerPath.hasSuffix(fragment))
    }

    private static func containsBuildNestedDirectory(
        _ directory: String,
        in lowerPath: String,
        isDirectory: Bool
    ) -> Bool {
        let components = lowerPath.split(separator: "/", omittingEmptySubsequences: true)
        for index in components.indices
            where components[index] == ".build"
                && index + 2 < components.count
                && components[index + 2] == Substring(directory) {
            return index + 2 < components.count - 1 || isDirectory
        }
        return false
    }

    private static func containsNestedBuildIndexStore(in lowerPath: String, isDirectory: Bool) -> Bool {
        let components = lowerPath.split(separator: "/", omittingEmptySubsequences: true)
        for buildIndex in components.indices where components[buildIndex] == ".build" {
            guard buildIndex + 3 < components.count else { continue }
            for index in (buildIndex + 2)..<(components.count - 1)
                where components[index] == "index" && components[index + 1] == "store" {
                return index + 1 < components.count - 1 || isDirectory
            }
        }
        return false
    }

    private static func containsNestedBuildTemporary(in lowerPath: String) -> Bool {
        let components = lowerPath.split(separator: "/", omittingEmptySubsequences: true)
        return components.indices.contains { index in
            components[index] == "build" && index + 2 < components.count
        }
    }

    private static func containsBuildDependencyDirectory(in lowerPath: String, isDirectory: Bool) -> Bool {
        let components = lowerPath.split(separator: "/", omittingEmptySubsequences: true)
        for buildIndex in components.indices where components[buildIndex] == "build" {
            guard buildIndex + 1 < components.count else { continue }
            for dependencyIndex in (buildIndex + 1)..<components.count
                where components[dependencyIndex] == "_deps" {
                return dependencyIndex < components.count - 1 || isDirectory
            }
        }
        return false
    }

    private static func shouldQueue(
        _ event: FileSystemEvent,
        exclusionDecision: (String, Bool) -> FileExclusionRules.Decision,
        instrumentation: inout Instrumentation
    ) -> Bool {
        if event.itemIsDirectory {
            instrumentation.compiledDecisionCount += 1
            return exclusionDecision(event.path, true) != .prune
        }

        instrumentation.compiledDecisionCount += 1
        let fileDecision = exclusionDecision(event.path, false)
        if fileDecision != .prune {
            return true
        }

        instrumentation.compiledDecisionCount += 1
        let directoryDecision = exclusionDecision(event.path, true)
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

/// A component trie keeps scope collapsing and coverage checks proportional to path
/// depth instead of comparing every path with every queued scope.
struct FSEventPathScopeIndex {
    struct Instrumentation: Equatable, Sendable {
        var insertedPathCount = 0
        var coverageQueryCount = 0
        var componentVisitCount = 0
    }

    private struct Node {
        var children: [Substring: Int] = [:]
        var scopePath: String?
    }

    private var nodes = [Node()]
    private(set) var instrumentation = Instrumentation()

    mutating func insert(_ path: String) {
        instrumentation.insertedPathCount += 1
        var nodeIndex = 0

        if nodes[nodeIndex].scopePath != nil {
            return
        }

        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            instrumentation.componentVisitCount += 1
            if let childIndex = nodes[nodeIndex].children[component] {
                nodeIndex = childIndex
            } else {
                let childIndex = nodes.count
                nodes.append(Node())
                nodes[nodeIndex].children[component] = childIndex
                nodeIndex = childIndex
            }

            if nodes[nodeIndex].scopePath != nil {
                return
            }
        }

        nodes[nodeIndex].scopePath = path
        // A newly inserted parent supersedes any descendant scopes already present.
        nodes[nodeIndex].children.removeAll(keepingCapacity: false)
    }

    mutating func containsScope(covering path: String) -> Bool {
        instrumentation.coverageQueryCount += 1
        var nodeIndex = 0
        if nodes[nodeIndex].scopePath != nil {
            return true
        }

        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            instrumentation.componentVisitCount += 1
            guard let childIndex = nodes[nodeIndex].children[component] else {
                return false
            }
            nodeIndex = childIndex
            if nodes[nodeIndex].scopePath != nil {
                return true
            }
        }

        return false
    }

    var collapsedScopes: [String] {
        var scopes: [String] = []
        var pendingNodeIndexes = [0]
        while let nodeIndex = pendingNodeIndexes.popLast() {
            if let scopePath = nodes[nodeIndex].scopePath {
                scopes.append(scopePath)
            } else {
                pendingNodeIndexes.append(contentsOf: nodes[nodeIndex].children.values)
            }
        }
        return scopes.sorted()
    }

    static func collapse(_ paths: Set<String>) -> [String] {
        var index = FSEventPathScopeIndex()
        for path in paths {
            index.insert(path)
        }
        return index.collapsedScopes
    }
}

enum FSEventLiveRefreshScopeRouter {
    static func route(events: [FileSystemEvent], rootPaths: [String]) -> FSEventLiveRefreshScopeRouting {
        let rootMatcher = FSEventRootMatcher(rootPaths: rootPaths)
        var exactPaths = Set<String>()
        var directoryScopes = Set<String>()
        var recursivePaths = Set<String>()

        for event in events {
            let path = event.path
            if event.invalidatesEntireStream {
                directoryScopes.formUnion(rootMatcher.rootPaths)
                recursivePaths.formUnion(rootMatcher.rootPaths)
                continue
            }

            guard let rootPath = rootMatcher.matchingRoot(for: path) else {
                if event.requiresRecursiveRescan {
                    directoryScopes.formUnion(rootMatcher.rootPaths)
                    recursivePaths.formUnion(rootMatcher.rootPaths)
                }
                continue
            }

            if event.requiresDirectoryRefreshScope {
                let scope = directoryScope(for: event, path: path, rootPath: rootPath)
                directoryScopes.insert(scope)
                if event.requiresRecursiveRescan {
                    recursivePaths.insert(scope)
                }
            } else {
                exactPaths.insert(path)
            }
        }

        var directoryScopeIndex = FSEventPathScopeIndex()
        for scope in directoryScopes {
            directoryScopeIndex.insert(scope)
        }
        if !directoryScopes.isEmpty {
            exactPaths = exactPaths.filter { !directoryScopeIndex.containsScope(covering: $0) }
        }

        return FSEventLiveRefreshScopeRouting(
            exactPaths: exactPaths.sorted(),
            directoryPaths: directoryScopeIndex.collapsedScopes,
            recursivePaths: recursivePaths.sorted()
        )
    }

    private static func directoryScope(
        for event: FileSystemEvent,
        path: String,
        rootPath: String
    ) -> String {
        guard path != rootPath else { return rootPath }
        if event.itemIsDirectory {
            return path
        }

        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
        guard pathIsWithinRoot(parent, root: rootPath) else {
            return rootPath
        }
        return parent
    }

    private static func pathIsWithinRoot(_ path: String, root: String) -> Bool {
        root == "/" || path == root || path.hasPrefix(root + "/")
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

    private let rootMatcher: FSEventRootMatcher
    private let rootPaths: [String]
    private let exclusions: FileExclusionRules
    private var exclusionEvaluator: ((String, Bool) -> FileExclusionRules.Decision)?
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
        let rootMatcher = FSEventRootMatcher(rootPaths: rootPaths)
        self.rootMatcher = rootMatcher
        self.rootPaths = rootMatcher.rootPaths
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

            let decision: FileExclusionRules.Decision
            if usesKnownExclusionFastPath {
                if FSEventIndexFilter.isKnownExcludedEventPath(
                    event.path,
                    activePatterns: activeExclusionPatterns,
                    isDirectory: event.itemIsDirectory
                ) {
                    droppedExcludedEventCount += 1
                    continue
                }
                decision = .index
            } else {
                decision = exclusionDecision(for: event)
            }
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
        rootMatcher.matchingRoot(for: path)
    }

    private func exclusionDecision(for event: FileSystemEvent) -> FileExclusionRules.Decision {
        let evaluator: (String, Bool) -> FileExclusionRules.Decision
        if let exclusionEvaluator {
            evaluator = exclusionEvaluator
        } else {
            let newEvaluator = exclusions.makeDecisionEvaluator(roots: rootPaths)
            exclusionEvaluator = newEvaluator
            evaluator = newEvaluator
        }

        let decision = evaluator(event.path, event.itemIsDirectory)
        guard decision == .prune, !event.itemIsDirectory else { return decision }

        let directoryDecision = evaluator(event.path, true)
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
        FSEventPathScopeIndex.collapse(paths)
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
