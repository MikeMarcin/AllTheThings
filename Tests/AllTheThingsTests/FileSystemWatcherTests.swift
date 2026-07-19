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

        let filtered = FSEventIndexFilter.indexableEvents(
            [
                FileSystemEvent(path: reIncludedPath, flags: 0, eventID: 41),
                FileSystemEvent(path: excludedPath, flags: 0, eventID: 42)
            ],
            rootPaths: [root.path],
            exclusionPatterns: patterns
        )

        #expect(filtered.map(\.path) == [reIncludedPath])
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
        #expect(!FSEventDefaultExclusionPolicy.matches([
            "node_modules/",
            "!node_modules/acme/**"
        ]))
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
            "\(root)/.next/cache/webpack/client.pack",
            "\(root)/build/debug/_deps/package/CMakeLists.txt",
            "\(root)/Sources/__pycache__/module.pyc",
            "\(root)/coverage/default.profraw",
            "\(root)/App.dSYM/Contents/Resources/DWARF/App",
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

    @Test("live FSEvents route exact files separately from broad directory scopes")
    func liveFSEventsRouteExactFilesSeparatelyFromBroadDirectoryScopes() {
        let root = "/tmp/allthethings/root-a"
        let safeFile = "\(root)/Sources/App.swift"
        let assetDirectory = "\(root)/Assets"
        let coveredAsset = "\(assetDirectory)/sprite.png"
        let deletedFile = "\(root)/Deleted/Old.swift"
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
                    path: recursiveFile,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs),
                    eventID: 5
                )
            ],
            rootPaths: [root]
        )

        #expect(routed.exactPaths == [safeFile])
        #expect(Set(routed.directoryPaths) == [
            assetDirectory,
            "\(root)/Deleted",
            "\(root)/Generated"
        ])
        #expect(routed.recursivePaths == ["\(root)/Generated"])
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
        #expect(Set(routed.directoryPaths) == Set(roots))
        #expect(Set(routed.recursivePaths) == Set(roots))
        #expect(!routed.directoryPaths.contains("/"))
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
