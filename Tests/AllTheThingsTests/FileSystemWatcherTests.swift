@testable import AllTheThings
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

    @Test("FSEvent reconciliation refreshes normal historical paths")
    func fseventReconciliationRefreshesNormalHistoricalPaths() async {
        let root = URL(fileURLWithPath: "/tmp/allthethings/root-a", isDirectory: true)
        let changedPath = root.appendingPathComponent("log.txt").path
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
        #expect(action == .refresh(paths: [changedPath], cursorUpdates: [root.path: 41]))
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
        #expect(action == .fullReconcile(rootPaths: nil))
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
        #expect(action == .fullReconcile(rootPaths: [root.path]))
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
