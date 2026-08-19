@testable import AllTheThings
import ATTCore
import CoreServices
import Foundation
import Testing

@Suite("File system watcher")
struct FileSystemWatcherTests {
    @Test("FSEvent cursors persist in a sidecar")
    func fseventCursorsPersistInSidecar() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let cursorURL = directory.appendingPathComponent("fsevents-cursors.json", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let store = FSEventCursorStore(url: cursorURL)
        store.update([
            "/tmp/allthethings/root-a": 42,
            "/tmp/allthethings/root-b": 7
        ])

        #expect(store.eventID(for: "/tmp/allthethings/root-a") == 42)
        #expect(store.eventID(for: "/tmp/allthethings/root-b") == 7)

        store.update(["/tmp/allthethings/root-a": 12])
        #expect(store.eventID(for: "/tmp/allthethings/root-a") == 42)

        let reloaded = FSEventCursorStore(url: cursorURL)
        #expect(reloaded.eventID(for: "/tmp/allthethings/root-a") == 42)
        #expect(reloaded.eventID(for: "/tmp/allthethings/root-b") == 7)
    }

    @Test("FSEvent cursor store supports bulk baselines and invalidation")
    func fseventCursorsSupportBaselinesAndInvalidation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let cursorURL = directory.appendingPathComponent("fsevents-cursors.json", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let rootA = "/tmp/allthethings/root-a"
        let rootB = "/tmp/allthethings/root-b"
        let store = FSEventCursorStore(url: cursorURL)
        store.markBaseline(for: [rootA, rootB], eventID: 100)

        #expect(store.eventIDs(for: [rootA, rootB, "/tmp/allthethings/root-c"]) == [
            rootA: 100,
            rootB: 100
        ])

        store.invalidate(roots: [rootA])
        #expect(store.eventID(for: rootA) == nil)
        #expect(store.eventID(for: rootB) == 100)
    }

    @Test("live FSEvent cursor updates stay in memory until flush")
    func liveFSEventCursorUpdatesAreDeferred() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let cursorURL = directory.appendingPathComponent("fsevents-cursors.json", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let root = "/tmp/allthethings/root-a"
        let store = FSEventCursorStore(url: cursorURL, deferredUpdateInterval: 3_600)
        store.updateDeferred([root: 123])

        #expect(store.eventID(for: root) == 123)
        #expect(FSEventCursorStore(url: cursorURL).eventID(for: root) == nil)

        store.flushPendingUpdates()
        #expect(FSEventCursorStore(url: cursorURL).eventID(for: root) == 123)
    }

    @Test("cursor invalidation accepts a wrapped event epoch")
    func cursorInvalidationAcceptsWrappedEventEpoch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let cursorURL = directory.appendingPathComponent("fsevents-cursors.json", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let root = "/tmp/allthethings/root-a"
        let store = FSEventCursorStore(url: cursorURL, deferredUpdateInterval: 3_600)
        store.markBaseline(for: [root], eventID: 10_000)
        store.invalidate(roots: [root])
        store.updateDeferred([root: 12])

        #expect(store.eventID(for: root) == 12)
        #expect(FSEventCursorStore(url: cursorURL).eventID(for: root) == nil)

        store.flushPendingUpdates()
        #expect(FSEventCursorStore(url: cursorURL).eventID(for: root) == 12)

        store.updateDeferred([root: 15])
        store.flushPendingUpdates()
        #expect(FSEventCursorStore(url: cursorURL).eventID(for: root) == 15)
    }

    @Test("FSEvent flags classify historical completion and unsafe history")
    func fseventFlagsClassifyReplayState() {
        let historyDone = FileSystemEvent(
            path: "/tmp/allthethings",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone),
            eventID: 10
        )
        #expect(historyDone.historyReplayCompleted)
        #expect(!historyDone.historyIsUnsafe)
        #expect(!historyDone.requiresRecursiveRescan)

        let wrapped = FileSystemEvent(
            path: "/tmp/allthethings",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped),
            eventID: 11
        )
        #expect(!wrapped.historyReplayCompleted)
        #expect(wrapped.historyIsUnsafe)
        #expect(wrapped.requiresRecursiveRescan)

        let mustScan = FileSystemEvent(
            path: "/tmp/allthethings",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs),
            eventID: 12
        )
        #expect(!mustScan.historyIsUnsafe)
        #expect(mustScan.requiresRecursiveRescan)
    }

    @Test("FSEvent stream configuration defers background delivery")
    func fseventStreamConfigurationDefersBackgroundDelivery() {
        let interactive = FileSystemWatcher.StreamConfiguration.interactive
        let background = FileSystemWatcher.StreamConfiguration.background

        #expect(interactive.latency < background.latency)
        #expect(interactive.flags & UInt32(kFSEventStreamCreateFlagNoDefer) != 0)
        #expect(background.flags & UInt32(kFSEventStreamCreateFlagNoDefer) == 0)
        #expect(background.flags & UInt32(kFSEventStreamCreateFlagFileEvents) != 0)
        #expect(interactive.flags & UInt32(kFSEventStreamCreateFlagWatchRoot) != 0)
        #expect(background.flags & UInt32(kFSEventStreamCreateFlagWatchRoot) != 0)
    }

    @Test("stopped FSEvent sinks discard deliveries already queued for the main actor")
    @MainActor
    func stoppedFSEventSinksDiscardQueuedDeliveries() async {
        var deliveredEvents: [FileSystemEvent] = []
        let sink = FileSystemWatcher.EventSink { events in
            deliveredEvents.append(contentsOf: events)
        }

        sink.deliver([FileSystemEvent(path: "/tmp/allthethings/stale", flags: 0, eventID: 1)])
        sink.invalidate()
        await Task.yield()

        #expect(deliveredEvents.isEmpty)
    }

    @Test("FSEvent sinks coalesce callbacks before entering the main actor")
    @MainActor
    func fseventSinksCoalesceCallbacks() async {
        var deliveredBatches: [[FileSystemEvent]] = []
        let sink = FileSystemWatcher.EventSink { events in
            deliveredBatches.append(events)
        }
        let path = "/tmp/allthethings/changed"

        sink.deliver([FileSystemEvent(path: path, flags: 0, eventID: 1)])
        sink.deliver([
            FileSystemEvent(
                path: path,
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs),
                eventID: 2
            )
        ])
        await Task.yield()

        #expect(deliveredBatches.count == 1)
        #expect(deliveredBatches.first?.count == 1)
        #expect(deliveredBatches.first?.first?.eventID == 2)
        #expect(deliveredBatches.first?.first?.requiresRecursiveRescan == true)
    }

    @Test("FSEvent sinks split large callback bursts into bounded main actor deliveries")
    @MainActor
    func fseventSinksBoundLargeDeliveries() async {
        var deliveredBatches: [[FileSystemEvent]] = []
        let sink = FileSystemWatcher.EventSink { events in
            deliveredBatches.append(events)
        }
        let eventCount = FileSystemWatcher.EventSink.maximumEventsPerDelivery + 1
        let events = (0..<eventCount).map { offset in
            FileSystemEvent(
                path: "/tmp/allthethings/changed-\(offset)",
                flags: 0,
                eventID: FSEventStreamEventId(offset)
            )
        }

        sink.deliver(events)
        for _ in 0..<4 {
            await Task.yield()
        }

        #expect(deliveredBatches.count == 2)
        #expect(deliveredBatches.allSatisfy {
            $0.count <= FileSystemWatcher.EventSink.maximumEventsPerDelivery
        })
        #expect(deliveredBatches.reduce(0) { $0 + $1.count } == eventCount)
    }

    @Test("changing an FSEvent baseline restarts an otherwise identical stream")
    @MainActor
    func changingFSEventBaselineRestartsStream() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let watcher = FileSystemWatcher()
        defer { watcher.stop() }
        let firstBaseline = FSEventsGetCurrentEventId()
        let secondBaseline = firstBaseline &+ 1

        watcher.start(roots: [root], sinceWhen: firstBaseline) { _ in }
        #expect(watcher.sinceWhenForTesting() == firstBaseline)

        watcher.start(roots: [root], sinceWhen: secondBaseline) { _ in }
        #expect(watcher.sinceWhenForTesting() == secondBaseline)
    }

    @Test("application catalog invalidates for stream-wide control events")
    func applicationCatalogInvalidatesForStreamControlEvents() {
        let root = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let dropped = FileSystemEvent(
            path: "/",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped),
            eventID: 44
        )

        #expect(ApplicationSearchEventFilter.shouldInvalidate(events: [dropped], roots: [root]))
    }

    @Test("cursor advances map unsafe stream events to every configured root")
    func cursorAdvancesMapUnsafeEventsToConfiguredRoots() {
        let roots = ["/Users/example/Desktop", "/Users/example/Documents"]
        let events = [
            FileSystemEvent(
                path: "/",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped),
                eventID: 80
            ),
            FileSystemEvent(path: "\(roots[0])/Note.txt", flags: 0, eventID: 82)
        ]

        let advances = FSEventCursorAdvances.latestByRoot(events: events, rootPaths: roots)

        #expect(advances[roots[0]] == 82)
        #expect(advances[roots[1]] == 80)
    }

    @Test("wrapped cursor advances discard pre-wrap event IDs")
    func wrappedCursorAdvancesDiscardPreWrapEventIDs() {
        let roots = ["/Users/example/Desktop", "/Users/example/Documents"]
        let advances = FSEventCursorAdvances.latestByRoot(
            events: [
                FileSystemEvent(path: roots[0], flags: 0, eventID: 10_000),
                FileSystemEvent(
                    path: "/",
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped),
                    eventID: 12
                )
            ],
            rootPaths: roots,
            wrappedBaselineEventID: 20
        )

        #expect(advances == [roots[0]: 20, roots[1]: 20])
    }

    @Test("wrapped cursor advances survive same-path event coalescing")
    func wrappedCursorAdvancesSurviveSamePathCoalescing() {
        let root = "/Users/example/Desktop"
        let path = "\(root)/Note.txt"
        let merged = FileSystemEvent(path: path, flags: 0, eventID: 10_000).merging(
            FileSystemEvent(
                path: path,
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped),
                eventID: 12
            )
        )

        let advances = FSEventCursorAdvances.latestByRoot(
            events: [merged],
            rootPaths: [root],
            wrappedBaselineEventID: 20
        )

        #expect(merged.eventIDsWrapped)
        #expect(advances == [root: 20])
    }

    @Test("recursive repair events bypass exclusions")
    func recursiveRepairEventsBypassExclusions() {
        let root = "/tmp/allthethings/root-a"
        let mustScanPath = "\(root)/node_modules/acme/cache"
        let wrappedPath = "\(root)/node_modules/other/cache"
        let ordinaryExcludedPath = "\(root)/node_modules/ignored/file.js"
        let filtered = FSEventIndexFilter.indexableEvents(
            [
                FileSystemEvent(
                    path: mustScanPath,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs),
                    eventID: 41
                ),
                FileSystemEvent(
                    path: wrappedPath,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped),
                    eventID: 42
                ),
                FileSystemEvent(path: ordinaryExcludedPath, flags: 0, eventID: 43)
            ],
            rootPaths: [root],
            exclusionPatterns: FileExclusionRules.defaultPatterns
        )

        #expect(Set(filtered.map(\.eventID)) == [41, 42])
    }

    @Test("FSEvent reconciliation scopes normal historical file paths exactly")
    func fseventReconciliationScopesNormalHistoricalFilePathsExactly() async {
        let root = URL(fileURLWithPath: "/tmp/allthethings/root-a", isDirectory: true)
        let folder = root.appendingPathComponent("Project", isDirectory: true)
        let changedPath = folder.appendingPathComponent("log.txt").path
        let store = memoryCursorStore()
        store.markBaseline(for: [root.path], eventID: 40)
        let source = FakeHistoryReplaySource(
            events: [
                FileSystemEvent(path: changedPath, flags: 0, eventID: 41),
                FileSystemEvent(
                    path: root.path,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone),
                    eventID: 42
                )
            ],
            completion: .completed
        )
        let coordinator = FSEventReconciliationCoordinator(
            cursorStore: store,
            replaySource: source,
            currentEventID: { 42 }
        )

        let action = await actionFromCoordinator(coordinator, roots: [root])
        #expect(source.requestedSinceEventID == 40)
        #expect(action == .reconcile(paths: [changedPath], baselineEventID: 42))
    }

    @Test("FSEvent reconciliation scopes removed files to parent folders")
    func fseventReconciliationScopesRemovedFilesToParentFolders() async {
        let root = URL(fileURLWithPath: "/tmp/allthethings/root-a", isDirectory: true)
        let folder = root.appendingPathComponent("Project", isDirectory: true)
        let changedPath = folder.appendingPathComponent("deleted.txt").path
        let store = memoryCursorStore()
        store.markBaseline(for: [root.path], eventID: 40)
        let source = FakeHistoryReplaySource(
            events: [
                FileSystemEvent(
                    path: changedPath,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved),
                    eventID: 41
                ),
                FileSystemEvent(
                    path: root.path,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone),
                    eventID: 42
                )
            ],
            completion: .completed
        )
        let coordinator = FSEventReconciliationCoordinator(
            cursorStore: store,
            replaySource: source,
            currentEventID: { 42 }
        )

        let action = await actionFromCoordinator(coordinator, roots: [root])
        #expect(action == .reconcile(paths: [folder.path], baselineEventID: 42))
    }

    @Test("FSEvent reconciliation scopes normal historical directory paths directly")
    func fseventReconciliationScopesNormalHistoricalDirectoryPathsDirectly() async {
        let root = URL(fileURLWithPath: "/tmp/allthethings/root-a", isDirectory: true)
        let folder = root.appendingPathComponent("Project", isDirectory: true)
        let store = memoryCursorStore()
        store.markBaseline(for: [root.path], eventID: 40)
        let source = FakeHistoryReplaySource(
            events: [
                FileSystemEvent(
                    path: folder.path,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir),
                    eventID: 41
                ),
                FileSystemEvent(
                    path: root.path,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone),
                    eventID: 42
                )
            ],
            completion: .completed
        )
        let coordinator = FSEventReconciliationCoordinator(
            cursorStore: store,
            replaySource: source,
            currentEventID: { 42 }
        )

        let action = await actionFromCoordinator(coordinator, roots: [root])
        #expect(action == .reconcile(paths: [folder.path], baselineEventID: 42))
    }

    @Test("FSEvent reconciliation collapses large historical file sets to parent scopes")
    func fseventReconciliationCollapsesLargeHistoricalFileSetsToParentScopes() async {
        let root = URL(fileURLWithPath: "/tmp/allthethings/root-a", isDirectory: true)
        let store = memoryCursorStore()
        store.markBaseline(for: [root.path], eventID: 40)
        var events = (0...5_000).map { offset in
            FileSystemEvent(
                path: root.appendingPathComponent("changed-\(offset).txt").path,
                flags: 0,
                eventID: FSEventStreamEventId(41 + offset)
            )
        }
        events.append(FileSystemEvent(
            path: root.path,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone),
            eventID: 6_000
        ))
        let source = FakeHistoryReplaySource(events: events, completion: .completed)
        let coordinator = FSEventReconciliationCoordinator(
            cursorStore: store,
            replaySource: source,
            currentEventID: { 6_000 }
        )

        let action = await actionFromCoordinator(coordinator, roots: [root])
        #expect(action == .reconcile(paths: [root.path], baselineEventID: 6_000))
    }

    @Test("FSEvent reconciliation drops excluded git churn before collapse")
    func fseventReconciliationDropsExcludedGitChurnBeforeCollapse() async {
        let root = URL(fileURLWithPath: "/tmp/allthethings/root-a", isDirectory: true)
        let store = memoryCursorStore()
        store.markBaseline(for: [root.path], eventID: 40)
        let source = FakeHistoryReplaySource(
            events: [
                FileSystemEvent(
                    path: root.appendingPathComponent(".git/objects/ab/cdef").path,
                    flags: 0,
                    eventID: 41
                ),
                FileSystemEvent(
                    path: root.appendingPathComponent(".git/FETCH_HEAD").path,
                    flags: 0,
                    eventID: 42
                ),
                FileSystemEvent(
                    path: root.appendingPathComponent("build/debug/_deps/package/CMakeLists.txt").path,
                    flags: 0,
                    eventID: 43
                ),
                FileSystemEvent(
                    path: root.appendingPathComponent("build/debug/CMakeCache.txt.tmp123").path,
                    flags: 0,
                    eventID: 44
                ),
                FileSystemEvent(
                    path: root.path,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone),
                    eventID: 45
                )
            ],
            completion: .completed
        )
        let coordinator = FSEventReconciliationCoordinator(
            cursorStore: store,
            replaySource: source,
            currentEventID: { 45 }
        )

        let action = await actionFromCoordinator(coordinator, roots: [root])
        #expect(action == .upToDate(baselineEventID: 45))
    }

    @Test("FSEvent reconciliation keeps allowed git paths after filtering")
    func fseventReconciliationKeepsAllowedGitPathsAfterFiltering() async {
        let root = URL(fileURLWithPath: "/tmp/allthethings/root-a", isDirectory: true)
        let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        let store = memoryCursorStore()
        store.markBaseline(for: [root.path], eventID: 40)
        let source = FakeHistoryReplaySource(
            events: [
                FileSystemEvent(
                    path: gitDirectory.appendingPathComponent("config").path,
                    flags: 0,
                    eventID: 41
                ),
                FileSystemEvent(
                    path: root.path,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone),
                    eventID: 42
                )
            ],
            completion: .completed
        )
        let coordinator = FSEventReconciliationCoordinator(
            cursorStore: store,
            replaySource: source,
            currentEventID: { 42 }
        )

        let action = await actionFromCoordinator(coordinator, roots: [root])
        #expect(action == .reconcile(paths: [gitDirectory.appendingPathComponent("config").path], baselineEventID: 42))
    }

    @Test("live FSEvents drop excluded paths before update queuing")
    func liveFSEventsDropExcludedPathsBeforeUpdateQueuing() {
        let root = URL(fileURLWithPath: "/tmp/allthethings/root-a", isDirectory: true)
        let sourcePath = root.appendingPathComponent("Sources/App.swift").path
        let allowedGitPath = root.appendingPathComponent(".git/config").path
        let events = [
            FileSystemEvent(
                path: root.appendingPathComponent(".git/objects/ab/cdef").path,
                flags: 0,
                eventID: 41
            ),
            FileSystemEvent(
                path: root.appendingPathComponent(".git/FETCH_HEAD").path,
                flags: 0,
                eventID: 42
            ),
            FileSystemEvent(
                path: root.appendingPathComponent("build/module.o").path,
                flags: 0,
                eventID: 43
            ),
            FileSystemEvent(
                path: root.appendingPathComponent("build/CMakeFiles").path,
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir),
                eventID: 44
            ),
            FileSystemEvent(
                path: root.appendingPathComponent("build/debug/_deps/package/CMakeLists.txt").path,
                flags: 0,
                eventID: 45
            ),
            FileSystemEvent(
                path: root.appendingPathComponent("build/debug/CMakeCache.txt.tmp123").path,
                flags: 0,
                eventID: 46
            ),
            FileSystemEvent(path: allowedGitPath, flags: 0, eventID: 47),
            FileSystemEvent(
                path: sourcePath,
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs),
                eventID: 48
            )
        ]

        let filtered = FSEventIndexFilter.indexableEvents(
            events,
            rootPaths: [root.path],
            exclusionPatterns: FileExclusionRules.defaultPatterns
        )

        #expect(filtered.map(\.path) == [allowedGitPath, sourcePath])
        #expect(filtered.map(\.eventID) == [47, 48])
        #expect(filtered.last?.requiresRecursiveRescan == true)
    }

    @Test("custom negated exclusions reinclude live FSEvents")
    func customNegatedExclusionsReincludeLiveEvents() {
        let root = URL(fileURLWithPath: "/tmp/allthethings/root-a", isDirectory: true)
        let reIncludedPath = root.appendingPathComponent("node_modules/acme/Sources/App.js").path
        let excludedPath = root.appendingPathComponent("node_modules/other/index.js").path
        let patterns = ["node_modules/", "!node_modules/acme/**"]
        var instrumentation = FSEventIndexFilter.Instrumentation()

        let filtered = FSEventIndexFilter.indexableEvents(
            [
                FileSystemEvent(path: reIncludedPath, flags: 0, eventID: 41),
                FileSystemEvent(path: excludedPath, flags: 0, eventID: 42)
            ],
            context: FSEventIndexFilter.Context(
                rootPaths: [root.path],
                exclusionPatterns: patterns
            ),
            instrumentation: &instrumentation
        )

        #expect(filtered.map(\.path) == [reIncludedPath])
        #expect(instrumentation.defaultFastPathDecisionCount == 0)
        #expect(instrumentation.compiledQueryBuildCount == 1)
        #expect(instrumentation.compiledDecisionCount == 3)
    }

    @Test("default filtering keeps large bursts on the known-rule fast path")
    func defaultFilteringKeepsLargeBurstsOnFastPath() {
        let root = "/tmp/allthethings/root-a"
        let eventCount = 10_000
        var events: [FileSystemEvent] = []
        events.reserveCapacity(eventCount * 2)
        for offset in 0..<eventCount {
            events.append(FileSystemEvent(
                path: "\(root)/Sources/Generated/Module-\(offset).swift",
                flags: 0,
                eventID: FSEventStreamEventId(offset * 2 + 1)
            ))
            events.append(FileSystemEvent(
                path: "\(root)/.build/arm64-apple-macosx/debug/Module-\(offset).swift.o",
                flags: 0,
                eventID: FSEventStreamEventId(offset * 2 + 2)
            ))
        }
        var instrumentation = FSEventIndexFilter.Instrumentation()

        let filtered = FSEventIndexFilter.indexableEvents(
            events,
            context: FSEventIndexFilter.Context(
                rootPaths: [root],
                exclusionPatterns: FileExclusionRules.defaultPatterns,
                eventsArePreCoalesced: true
            ),
            instrumentation: &instrumentation
        )

        #expect(filtered.count == eventCount)
        #expect(instrumentation.defaultFastPathDecisionCount == eventCount * 2)
        #expect(instrumentation.compiledQueryBuildCount == 0)
        #expect(instrumentation.compiledDecisionCount == 0)
        #expect(instrumentation.redundantCoalescingEventCountAvoided == eventCount * 2)
    }

    @Test("default FSEvent fast path matches ordered-rule boundary semantics")
    func defaultFastPathMatchesOrderedRuleBoundaries() {
        let root = "/tmp/project"
        let samples: [(path: String, isDirectory: Bool)] = [
            ("\(root)/Sources/App.swift", false),
            ("\(root)/.git", true),
            ("\(root)/.git/config", false),
            ("\(root)/.git/HEAD", false),
            ("\(root)/.git/description", false),
            ("\(root)/.git/hooks", true),
            ("\(root)/.git/hooks/pre-commit", false),
            ("\(root)/.git/hooks/cache.pyc", false),
            ("\(root)/.git/hooks/node_modules/package.json", false),
            ("\(root)/.git/info/exclude", false),
            ("\(root)/.git/objects/ab/cdef", false),
            ("\(root)/.hg/store/data.i", false),
            ("\(root)/.svn/pristine/ab/file.svn-base", false),
            ("\(root)/node_modules/react/index.js", false),
            ("\(root)/DerivedData/Build/App", false),
            ("\(root)/.gradle/caches/state.bin", false),
            ("\(root)/.dart_tool/package_config.json", false),
            ("\(root)/.next/cache/client.pack", false),
            ("\(root)/.parcel-cache/state", false),
            ("\(root)/.turbo/log", false),
            ("\(root)/Example.app/Contents/_CodeSignature/CodeResources", false),
            ("\(root)/Xcode.app/Contents/Developer/Platforms/macOS.platform/Info.plist", false),
            ("\(root)/Xcode.app/Contents/Developer/Toolchains/Default/usr/bin/swift", false),
            ("\(root)/Engine/Binaries/ThirdParty/DotNet/runtime.dll", false),
            ("\(root)/Engine/Binaries/ThirdParty/Python3/Lib/os.py", false),
            ("\(root)/Engine/DerivedDataCache/cache.bin", false),
            ("\(root)/Engine/Intermediate/Build/Target.make", false),
            ("\(root)/Engine/Saved/Logs/Editor.log", false),
            ("\(root)/Engine/Content/Textures/Hero.png", false),
            ("\(root)/.build/index/store", true),
            ("\(root)/.build/arm64/index/store", true),
            ("\(root)/.build/arm64/index/store/v5/record", false),
            ("\(root)/.build/debug/App", false),
            ("\(root)/.build/release/App", false),
            ("\(root)/.build/arm64/debug/App", false),
            ("\(root)/.build/arm64/release/App", false),
            ("\(root)/.build/arm64/index/build.db", false),
            ("\(root)/.build/arm64/ModuleCache/SwiftShims.pcm", false),
            ("\(root)/.build/plugins/cache/tool-output.json", false),
            ("\(root)/.build/artifacts/package/checksum.zip", false),
            ("\(root)/.build/checkouts/Dependency/Sources/App.swift", false),
            ("\(root)/build/CMakeFiles/Target.dir/state", false),
            ("\(root)/build/Testing/Temporary/LastTest.log", false),
            ("\(root)/buck-out/gen/App.o", false),
            ("\(root)/bazel-out/bin/App", false),
            ("\(root)/.buckd/state.db", false),
            ("\(root)/build/.cmake/api/v1/reply.json", false),
            ("\(root)/build/_deps/Package/CMakeLists.txt", false),
            ("\(root)/build/debug/_deps/Package/CMakeLists.txt", false),
            ("\(root)/_deps/source/build/App.swift", false),
            ("\(root)/build/.tmp-cache", false),
            ("\(root)/build/generated/.tmp-cache", false),
            ("\(root)/build/App.o", false),
            ("\(root)/module.pyc", false),
            ("\(root)/module.pyo", false),
            ("\(root)/build/App.dSYM/Contents/Resources/DWARF/App", false),
            ("\(root)/coverage.gcda", false),
            ("\(root)/coverage.gcno", false),
            ("\(root)/coverage.profraw", false),
            ("\(root)/coverage.profdata", false),
            ("\(root)/.venv/lib/python/site.py", false),
            ("\(root)/venv/lib/python/site.py", false),
            ("\(root)/.tox/state", false),
            ("\(root)/__pycache__/module.pyc", false),
            ("\(root)/.pytest_cache/state", false),
            ("\(root)/.mypy_cache/state", false),
            ("\(root)/.ruff_cache/state", false),
            ("\(root)/.cache/state", false),
            ("\(root)/Library/Application Support/AllTheThings", true),
            ("\(root)/Library/Application Support/AllTheThings/Logs/diagnostic-log.jsonl", false),
            ("\(root)/Library/Caches/com.example/state", false),
            ("\(root)/.Trash/deleted.txt", false),
            ("\(root)/node_modules-copy/index.js", false),
            ("\(root)/node_modules", false),
            ("\(root)/nested/node_modules", true),
            ("\(root)/.build/debug", false),
            ("\(root)/nested/.build/debug", true),
            ("\(root)/build/App", false)
        ]
        let events = samples.enumerated().map { offset, sample in
            FileSystemEvent(
                path: sample.path,
                flags: sample.isDirectory
                    ? FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
                    : 0,
                eventID: FSEventStreamEventId(offset + 1)
            )
        }

        let filtered = FSEventIndexFilter.indexableEvents(
            events,
            rootPaths: [root],
            exclusionPatterns: FileExclusionRules.defaultPatterns
        )
        let rules = FileExclusionRules()
        let expectedPaths = samples.compactMap { sample -> String? in
            let url = URL(fileURLWithPath: sample.path, isDirectory: sample.isDirectory)
            let decision = rules.decision(url: url, roots: [root], isDirectory: sample.isDirectory)
            if decision != .prune { return sample.path }
            guard !sample.isDirectory else { return nil }
            let directoryDecision = rules.decision(url: url, roots: [root], isDirectory: true)
            return directoryDecision == .prune ? nil : sample.path
        }

        #expect(filtered.map(\.path) == expectedPaths)
    }

    @Test("migrated default exclusion order retains the known fast path")
    func migratedDefaultExclusionOrderRetainsKnownFastPath() {
        let defaults = FileExclusionRules.defaultPatterns
        let migratedOrder = Array(defaults.prefix(6)) + Array(defaults.dropFirst(6).reversed())

        #expect(FSEventDefaultExclusionPolicy.matches(migratedOrder))
        #expect(FSEventIndexFilter.Context(
            rootPaths: ["/tmp/allthethings/root-a"],
            exclusionPatterns: migratedOrder
        ).usesKnownExclusionFastPath)
        let unsafeOrder = [defaults.last!] + Array(defaults.dropLast())
        #expect(!FSEventDefaultExclusionPolicy.matches(unsafeOrder))
        #expect(!FSEventDefaultExclusionPolicy.matches([
            "node_modules/",
            "!node_modules/acme/**"
        ]))
    }

    @Test("default historical filtering applies later exclusions inside re-included git paths")
    func defaultHistoricalFilteringAppliesRulesAfterGitReinclusion() async {
        let root = URL(fileURLWithPath: "/tmp/allthethings/root-a", isDirectory: true)
        let store = memoryCursorStore()
        store.markBaseline(for: [root.path], eventID: 40)
        let source = FakeHistoryReplaySource(
            events: [
                FileSystemEvent(
                    path: root.appendingPathComponent(".git/hooks/cache.pyc").path,
                    flags: 0,
                    eventID: 41
                ),
                FileSystemEvent(
                    path: root.path,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone),
                    eventID: 42
                )
            ],
            completion: .completed
        )
        let coordinator = FSEventReconciliationCoordinator(
            cursorStore: store,
            replaySource: source,
            currentEventID: { 42 }
        )

        let action = await actionFromCoordinator(
            coordinator,
            roots: [root],
            exclusions: FileExclusionRules()
        )
        #expect(action == .upToDate(baselineEventID: 42))
    }

    @Test("custom negated exclusions reinclude historical FSEvents")
    func customNegatedExclusionsReincludeHistoricalEvents() async {
        let root = URL(fileURLWithPath: "/tmp/allthethings/root-a", isDirectory: true)
        let reIncludedPath = root.appendingPathComponent("node_modules/acme/Sources/App.js").path
        let store = memoryCursorStore()
        store.markBaseline(for: [root.path], eventID: 40)
        let source = FakeHistoryReplaySource(
            events: [
                FileSystemEvent(path: reIncludedPath, flags: 0, eventID: 41),
                FileSystemEvent(
                    path: root.path,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone),
                    eventID: 42
                )
            ],
            completion: .completed
        )
        let coordinator = FSEventReconciliationCoordinator(
            cursorStore: store,
            replaySource: source,
            currentEventID: { 42 }
        )

        let action = await actionFromCoordinator(
            coordinator,
            roots: [root],
            exclusions: FileExclusionRules(patterns: ["node_modules/", "!node_modules/acme/**"])
        )
        #expect(action == .reconcile(paths: [reIncludedPath], baselineEventID: 42))
    }

    @Test("known excluded FSEvent paths cover default generated churn")
    func knownExcludedFSEventPathsCoverDefaultGeneratedChurn() {
        let root = "/tmp/allthethings/root-a"
        let patterns = Set(FileExclusionRules.defaultPatterns)
        let excludedPaths = [
            "\(root)/.git/objects/ab/cdef",
            "\(root)/.git/FETCH_HEAD",
            "\(root)/.gradle/caches/modules-2/files-2.1/module.bin",
            "\(root)/.build/debug/index/store/records",
            "\(root)/.build/debug/AllTheThings.build/main.swift.o",
            "\(root)/.build/arm64-apple-macosx/debug/AllTheThings.build/App.swift.o",
            "\(root)/.build/arm64-apple-macosx/ModuleCache/SwiftShims.pcm",
            "\(root)/.build/plugins/cache/tool-output.json",
            "\(root)/.build/artifacts/package/checksum.zip",
            "\(root)/Example.app/Contents/_CodeSignature/CodeResources",
            "\(root)/Xcode.app/Contents/Developer/Platforms/macOS.platform/Info.plist",
            "\(root)/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift",
            "\(root)/Engine/Binaries/ThirdParty/DotNet/runtime.dll",
            "\(root)/Engine/Binaries/ThirdParty/Python3/Lib/os.py",
            "\(root)/Engine/DerivedDataCache/cache.bin",
            "\(root)/Engine/Intermediate/Build/Target.make",
            "\(root)/Engine/Saved/Logs/Editor.log",
            "\(root)/buck-out/gen/App.o",
            "\(root)/bazel-out/bin/App.o",
            "\(root)/.buckd/state.db",
            "\(root)/.next/cache/webpack/client.pack",
            "\(root)/build/debug/_deps/package/CMakeLists.txt",
            "\(root)/Sources/__pycache__/module.pyc",
            "\(root)/coverage/default.profraw",
            "\(root)/App.dSYM/Contents/Resources/DWARF/App",
            "\(root)/Library/Application Support/AllTheThings/filename-index-v8.attindex/records.bin",
            "\(root)/Library/Caches/com.example/cache.db"
        ]

        for path in excludedPaths {
            #expect(FSEventIndexFilter.isKnownExcludedEventPath(path, activePatterns: patterns))
        }
        #expect(!FSEventIndexFilter.isKnownExcludedEventPath("\(root)/.git/config", activePatterns: patterns))
        #expect(!FSEventIndexFilter.isKnownExcludedEventPath("\(root)/.git/hooks/pre-commit", activePatterns: patterns))
        #expect(!FSEventIndexFilter.isKnownExcludedEventPath(
            "\(root)/.build/checkouts/Dependency/Sources/Dependency.swift",
            activePatterns: patterns
        ))
        #expect(!FSEventIndexFilter.isKnownExcludedEventPath(
            "\(root)/Library/Application Support/AnotherApp/state.db",
            activePatterns: patterns
        ))
    }

    @Test("FSEvent reconciliation routes files through updates and directories through reconciliation")
    func fseventReconciliationRoutesFilesAndDirectoriesSeparately() {
        let root = "/tmp/allthethings/root-a"
        let filePath = "\(root)/Sources/App.swift"
        let directoryPath = "\(root)/Assets"
        let childCoveredByDirectory = "\(directoryPath)/sprite.png"
        let missingPath = "\(root)/Deleted/File.swift"

        let routed = FSEventReconciliationScopeRouter.route(
            paths: [filePath, directoryPath, childCoveredByDirectory, missingPath, filePath],
            isDirectory: { $0 == directoryPath }
        )

        #expect(routed.directoryPaths == [directoryPath])
        #expect(routed.updatePaths == [filePath, missingPath])
    }

    @Test("live FSEvents reserve recursive work for events that can change a subtree")
    func liveFSEventsRouteExactAndRecursiveChangesSeparately() {
        let root = "/tmp/allthethings/root-a"
        let safeFile = "\(root)/Sources/App.swift"
        let assetDirectory = "\(root)/Assets"
        let coveredAsset = "\(assetDirectory)/sprite.png"
        let deletedFile = "\(root)/Deleted/Old.swift"
        let renamedFile = "\(root)/Sources/Renamed.swift"
        let recursiveFile = "\(root)/Generated/output.txt"

        let routed = FSEventLiveRefreshScopeRouter.route(
            events: [
                FileSystemEvent(path: safeFile, flags: 0, eventID: 1),
                FileSystemEvent(
                    path: assetDirectory,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir),
                    eventID: 2
                ),
                FileSystemEvent(path: coveredAsset, flags: 0, eventID: 3),
                FileSystemEvent(
                    path: deletedFile,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved),
                    eventID: 4
                ),
                FileSystemEvent(
                    path: renamedFile,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed),
                    eventID: 5
                ),
                FileSystemEvent(
                    path: recursiveFile,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs),
                    eventID: 6
                )
            ],
            rootPaths: [root]
        )

        #expect(Set(routed.exactPaths) == [
            assetDirectory,
            coveredAsset,
            deletedFile,
            renamedFile,
            safeFile
        ])
        #expect(routed.recursivePaths == ["\(root)/Generated"])
    }

    @Test("directory create and rename events recursively discover incoming contents")
    func directoryCreateAndRenameEventsRouteRecursively() {
        let root = "/tmp/allthethings/root-a"
        let createdDirectory = "\(root)/Created"
        let createdChild = "\(createdDirectory)/Existing.txt"
        let renamedDirectory = "\(root)/Renamed"
        let replacedDirectory = "\(root)/Replaced"
        let directoryFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)

        let routed = FSEventLiveRefreshScopeRouter.route(
            events: [
                FileSystemEvent(
                    path: createdDirectory,
                    flags: directoryFlags
                        | FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
                    eventID: 1
                ),
                FileSystemEvent(
                    path: renamedDirectory,
                    flags: directoryFlags
                        | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed),
                    eventID: 2
                ),
                FileSystemEvent(path: createdChild, flags: 0, eventID: 3),
                FileSystemEvent(
                    path: replacedDirectory,
                    flags: directoryFlags
                        | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
                        | FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
                    eventID: 4
                )
            ],
            rootPaths: [root]
        )

        #expect(routed.exactPaths.isEmpty)
        #expect(Set(routed.recursivePaths) == [createdDirectory, renamedDirectory, replacedDirectory])
    }

    @Test("directory metadata and removal events stay exact")
    func directoryMetadataAndRemovalEventsStayExact() {
        let root = "/tmp/allthethings/root-a"
        let metadataDirectory = "\(root)/MetadataOnly"
        let removedDirectory = "\(root)/Removed"
        let directoryFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)

        let routed = FSEventLiveRefreshScopeRouter.route(
            events: [
                FileSystemEvent(
                    path: metadataDirectory,
                    flags: directoryFlags
                        | FSEventStreamEventFlags(kFSEventStreamEventFlagItemInodeMetaMod),
                    eventID: 1
                ),
                FileSystemEvent(
                    path: removedDirectory,
                    flags: directoryFlags
                        | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved),
                    eventID: 2
                )
            ],
            rootPaths: [root]
        )

        #expect(Set(routed.exactPaths) == [metadataDirectory, removedDirectory])
        #expect(routed.recursivePaths.isEmpty)
    }

    @Test("large scope bursts collapse with path-depth bounded work")
    func largeScopeBurstsUsePathDepthBoundedWork() {
        let root = "/tmp/allthethings/root-a"
        let scopeCount = 2_000
        let queryCount = 10_000
        var scopeIndex = FSEventPathScopeIndex()

        // Insert descendants first to cover the expensive ordering for a flat-list collapse.
        for offset in 0..<scopeCount {
            let scope = "\(root)/package-\(offset)"
            scopeIndex.insert("\(scope)/Generated/Objects")
            scopeIndex.insert(scope)
        }

        for offset in 0..<queryCount {
            let scope = "\(root)/package-\(offset % scopeCount)"
            let isCovered = scopeIndex.containsScope(covering: "\(scope)/Sources/File-\(offset).swift")
            #expect(isCovered)
        }

        let prefixSiblingIsCovered = scopeIndex.containsScope(
            covering: "\(root)/package-0-copy/Sources/File.swift"
        )
        #expect(!prefixSiblingIsCovered)
        #expect(scopeIndex.collapsedScopes.count == scopeCount)
        #expect(scopeIndex.instrumentation.insertedPathCount == scopeCount * 2)
        #expect(scopeIndex.instrumentation.coverageQueryCount == queryCount + 1)
        #expect(
            scopeIndex.instrumentation.componentVisitCount
                <= (scopeIndex.instrumentation.insertedPathCount
                    + scopeIndex.instrumentation.coverageQueryCount) * 8
        )
    }

    @Test("cursor matching normalizes once and selects the most specific root")
    func cursorMatchingUsesMostSpecificCanonicalRoot() {
        let parentRoot = "/tmp/allthethings"
        let nestedRoot = "\(parentRoot)/root-a"
        let advances = FSEventCursorAdvances.latestByRoot(
            events: [
                FileSystemEvent(
                    path: "\(nestedRoot)/Sources/../Sources/App.swift/",
                    flags: 0,
                    eventID: 42
                )
            ],
            rootPaths: [parentRoot, nestedRoot]
        )

        #expect(advances == [nestedRoot: 42])
    }

    @Test("live FSEvents coalesce duplicate paths while preserving recursive flags")
    func liveFSEventsCoalesceDuplicatePathsWhilePreservingRecursiveFlags() {
        let root = URL(fileURLWithPath: "/tmp/allthethings/root-a", isDirectory: true)
        let sourcePath = root.appendingPathComponent("Sources/App.swift").path
        let filtered = FSEventIndexFilter.indexableEvents(
            [
                FileSystemEvent(path: sourcePath, flags: 0, eventID: 41),
                FileSystemEvent(
                    path: sourcePath,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs),
                    eventID: 45
                )
            ],
            rootPaths: [root.path],
            exclusionPatterns: FileExclusionRules.defaultPatterns
        )

        #expect(filtered.map(\.path) == [sourcePath])
        #expect(filtered.first?.eventID == 45)
        #expect(filtered.first?.requiresRecursiveRescan == true)
    }

    @Test("dropped live FSEvents rescan configured roots instead of the filesystem root")
    func droppedLiveFSEventsRescanConfiguredRoots() {
        let roots = [
            "/Users/example/Desktop",
            "/Users/example/Documents",
            "/Users/example/Downloads"
        ]
        let flags = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)

        let routed = FSEventLiveRefreshScopeRouter.route(
            events: [FileSystemEvent(path: "/", flags: flags, eventID: 100)],
            rootPaths: roots
        )

        #expect(routed.exactPaths.isEmpty)
        #expect(Set(routed.recursivePaths) == Set(roots))
        #expect(!routed.recursivePaths.contains("/"))
    }

    @Test("root invalidation recursively refreshes the affected configured root")
    func rootInvalidationRefreshesAffectedRootRecursively() {
        let affectedRoot = "/Users/example/Documents"
        let unaffectedRoot = "/Users/example/Downloads"
        let routed = FSEventLiveRefreshScopeRouter.route(
            events: [
                FileSystemEvent(
                    path: affectedRoot,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged),
                    eventID: 101
                )
            ],
            rootPaths: [affectedRoot, unaffectedRoot]
        )

        #expect(routed.exactPaths.isEmpty)
        #expect(routed.recursivePaths == [affectedRoot])
    }

    @Test("ordinary live FSEvents outside configured roots are ignored")
    func liveFSEventsOutsideConfiguredRootsAreIgnored() {
        let routed = FSEventLiveRefreshScopeRouter.route(
            events: [FileSystemEvent(path: "/tmp/unrelated.txt", flags: 0, eventID: 101)],
            rootPaths: ["/Users/example/Documents"]
        )

        #expect(routed.isEmpty)
        #expect(routed.recursivePaths.isEmpty)
    }

    @Test("FSEvent reconciliation falls back when a cursor is missing")
    func fseventReconciliationFallsBackForMissingCursor() async {
        let root = URL(fileURLWithPath: "/tmp/allthethings/root-a", isDirectory: true)
        let coordinator = FSEventReconciliationCoordinator(
            cursorStore: memoryCursorStore(),
            replaySource: FakeHistoryReplaySource(events: [], completion: .completed),
            currentEventID: { 50 }
        )

        let action = await actionFromCoordinator(coordinator, roots: [root])
        #expect(action == .fullReconcile(paths: nil, baselineEventID: 50))
    }

    @Test("FSEvent reconciliation falls back for unsafe history")
    func fseventReconciliationFallsBackForUnsafeHistory() async {
        let root = URL(fileURLWithPath: "/tmp/allthethings/root-a", isDirectory: true)
        let store = memoryCursorStore()
        store.markBaseline(for: [root.path], eventID: 40)
        let source = FakeHistoryReplaySource(
            events: [
                FileSystemEvent(
                    path: root.path,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped),
                    eventID: 41
                ),
                FileSystemEvent(
                    path: root.path,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone),
                    eventID: 42
                )
            ],
            completion: .completed
        )
        let coordinator = FSEventReconciliationCoordinator(
            cursorStore: store,
            replaySource: source,
            currentEventID: { 42 }
        )

        let action = await actionFromCoordinator(coordinator, roots: [root])
        #expect(action == .fullReconcile(paths: [root.path], baselineEventID: 42))
        #expect(store.eventID(for: root.path) == nil)

        store.markBaseline(for: [root.path], eventID: 42)
        #expect(store.eventID(for: root.path) == 42)
    }

    @Test("history completion cannot hide a dropped-stream flag")
    func historyCompletionWithDroppedFlagStillFallsBack() async {
        let root = URL(fileURLWithPath: "/tmp/allthethings/root-a", isDirectory: true)
        let store = memoryCursorStore()
        store.markBaseline(for: [root.path], eventID: 40)
        let source = FakeHistoryReplaySource(
            events: [
                FileSystemEvent(
                    path: "/",
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)
                        | FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped),
                    eventID: 45
                )
            ],
            completion: .completed
        )
        let coordinator = FSEventReconciliationCoordinator(
            cursorStore: store,
            replaySource: source,
            currentEventID: { 45 }
        )

        let action = await actionFromCoordinator(coordinator, roots: [root])
        #expect(action == .fullReconcile(paths: [root.path], baselineEventID: 45))
    }

    @Test("FSEvent reconciliation records up to date baselines")
    func fseventReconciliationRecordsUpToDateBaselines() async {
        let root = URL(fileURLWithPath: "/tmp/allthethings/root-a", isDirectory: true)
        let store = memoryCursorStore()
        store.markBaseline(for: [root.path], eventID: 40)
        let source = FakeHistoryReplaySource(
            events: [
                FileSystemEvent(
                    path: root.path,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone),
                    eventID: 40
                )
            ],
            completion: .completed
        )
        let coordinator = FSEventReconciliationCoordinator(
            cursorStore: store,
            replaySource: source,
            currentEventID: { 55 }
        )

        let action = await actionFromCoordinator(coordinator, roots: [root])
        #expect(action == .upToDate(baselineEventID: 40))
    }

    private func memoryCursorStore() -> FSEventCursorStore {
        FSEventCursorStore(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("fsevents-cursors.json", isDirectory: false)
        )
    }

    @MainActor
    private func actionFromCoordinator(
        _ coordinator: FSEventReconciliationCoordinator,
        roots: [URL],
        exclusions: FileExclusionRules = FileExclusionRules()
    ) async -> FSEventReconciliationAction {
        await withCheckedContinuation { continuation in
            _ = coordinator.reconcile(roots: roots, exclusions: exclusions) { action in
                continuation.resume(returning: action)
            }
        }
    }
}

private final class FakeHistoryReplaySource: FSEventHistoryReplaySource, @unchecked Sendable {
    let events: [FileSystemEvent]
    let completion: FSEventHistoryReplayCompletion
    private(set) var requestedSinceEventID: FSEventStreamEventId?

    init(events: [FileSystemEvent], completion: FSEventHistoryReplayCompletion) {
        self.events = events
        self.completion = completion
    }

    func replay(
        roots: [URL],
        sinceEventID: FSEventStreamEventId,
        timeout: TimeInterval,
        eventHandler: @escaping @Sendable ([FileSystemEvent]) -> Void,
        completion: @escaping @Sendable (FSEventHistoryReplayCompletion) -> Void
    ) -> FSEventHistoryReplayCancellable? {
        requestedSinceEventID = sinceEventID
        eventHandler(events)
        completion(self.completion)
        return FakeHistoryReplayCancellable()
    }
}

private final class FakeHistoryReplayCancellable: FSEventHistoryReplayCancellable, @unchecked Sendable {
    func cancel() {}
}
