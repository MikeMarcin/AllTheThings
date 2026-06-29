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

    @Test("FSEvent reconciliation falls back when a cursor is missing")
    func fseventReconciliationFallsBackForMissingCursor() async {
        let root = URL(fileURLWithPath: "/tmp/allthethings/root-a", isDirectory: true)
        let coordinator = FSEventReconciliationCoordinator(
            cursorStore: memoryCursorStore(),
            replaySource: FakeHistoryReplaySource(events: [], completion: .completed),
            currentEventID: { 50 }
        )

        let action = await actionFromCoordinator(coordinator, roots: [root])
        #expect(action == .fullReconcile(paths: nil))
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
        #expect(action == .fullReconcile(paths: [root.path]))
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
        #expect(action == .upToDate(baselineEventID: 55))
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
        roots: [URL]
    ) async -> FSEventReconciliationAction {
        await withCheckedContinuation { continuation in
            _ = coordinator.reconcile(roots: roots) { action in
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
