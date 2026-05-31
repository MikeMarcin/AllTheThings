import CoreServices
import Foundation

struct FileSystemEvent {
    let path: String
    let flags: FSEventStreamEventFlags
    let eventID: FSEventStreamEventId

    var historyReplayCompleted: Bool {
        flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0
    }

    var historyIsUnsafe: Bool {
        flags & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) != 0
            || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped) != 0
            || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
            || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped) != 0
    }

    var requiresRecursiveRescan: Bool {
        flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
            || historyIsUnsafe
    }
}

final class FileSystemWatcher {
    private let queue = DispatchQueue(label: "att.fsevents", qos: .utility)
    private let cursorStore: FSEventCursorStore
    private var stream: FSEventStreamRef?
    private var eventHandler: (@MainActor @Sendable ([FileSystemEvent]) -> Void)?
    private var rootPaths: [String] = []

    init(cursorStore: FSEventCursorStore = .default) {
        self.cursorStore = cursorStore
    }

    deinit {
        stop()
    }

    func start(roots: [URL], eventHandler: @escaping @MainActor @Sendable ([FileSystemEvent]) -> Void) {
        stop()

        let paths = roots.map { $0.standardizedFileURL.path }
        guard !paths.isEmpty else { return }

        self.eventHandler = eventHandler
        self.rootPaths = paths

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

        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes)
            | UInt32(kFSEventStreamCreateFlagFileEvents)
            | UInt32(kFSEventStreamCreateFlagNoDefer)

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,
            flags
        )

        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        rootPaths = []
    }

    private func handle(events: [FileSystemEvent]) {
        guard !events.isEmpty else { return }
        guard let eventHandler else { return }
        persistLatestEventIDs(from: events)

        Task { @MainActor in
            eventHandler(events)
        }
    }

    private func persistLatestEventIDs(from events: [FileSystemEvent]) {
        guard !rootPaths.isEmpty else { return }

        var latestByRoot: [String: UInt64] = [:]
        for event in events {
            guard let root = rootPaths.first(where: { event.path == $0 || event.path.hasPrefix($0 + "/") }) else {
                continue
            }
            latestByRoot[root] = max(latestByRoot[root] ?? 0, UInt64(event.eventID))
        }

        cursorStore.update(latestByRoot)
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
    case refresh(paths: [String], cursorUpdates: [String: UInt64])
    case upToDate(baselineEventID: UInt64)
    case fullReconcile(rootPaths: [String]?)
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
        completion: @escaping @MainActor @Sendable (FSEventReconciliationAction) -> Void
    ) -> FSEventHistoryReplayCancellable? {
        let rootPaths = roots.map { $0.standardizedFileURL.path }
        guard !rootPaths.isEmpty else {
            Task { @MainActor in completion(.upToDate(baselineEventID: currentEventID())) }
            return nil
        }

        let cursors = cursorStore.eventIDs(for: rootPaths)
        guard cursors.count == rootPaths.count, let sinceEventID = cursors.values.min(), sinceEventID > 0 else {
            Task { @MainActor in completion(.fullReconcile(rootPaths: nil)) }
            return nil
        }

        let collector = FSEventHistoryReplayCollector(rootPaths: rootPaths)
        guard let session = replaySource.replay(
            roots: roots,
            sinceEventID: FSEventStreamEventId(sinceEventID),
            timeout: timeout,
            eventHandler: { events in
                collector.ingest(events)
            },
            completion: { [currentEventID] result in
                let action = collector.action(completion: result, currentEventID: currentEventID())
                Task { @MainActor in
                    completion(action)
                }
            }
        ) else {
            Task { @MainActor in completion(.fullReconcile(rootPaths: nil)) }
            return nil
        }

        return session
    }
}

private final class FSEventHistoryReplayCollector: @unchecked Sendable {
    private let rootPaths: [String]
    private let lock = NSLock()
    private var changedPaths = Set<String>()
    private var fallbackRootPaths = Set<String>()
    private var requiresGlobalFallback = false
    private var cursorUpdates: [String: UInt64] = [:]
    private var sawHistoryDone = false

    init(rootPaths: [String]) {
        self.rootPaths = rootPaths.sorted { $0.count > $1.count }
    }

    func ingest(_ events: [FileSystemEvent]) {
        lock.lock()
        defer { lock.unlock() }

        for event in events {
            if event.historyReplayCompleted {
                sawHistoryDone = true
                continue
            }

            guard let rootPath = matchingRoot(for: event.path) else {
                requiresGlobalFallback = true
                continue
            }

            cursorUpdates[rootPath] = max(cursorUpdates[rootPath] ?? 0, UInt64(event.eventID))

            if event.historyIsUnsafe || event.requiresRecursiveRescan {
                fallbackRootPaths.insert(rootPath)
            } else {
                changedPaths.insert(event.path)
            }
        }
    }

    func action(completion: FSEventHistoryReplayCompletion, currentEventID: UInt64) -> FSEventReconciliationAction {
        lock.lock()
        defer { lock.unlock() }

        guard completion == .completed, sawHistoryDone else {
            return .fullReconcile(rootPaths: nil)
        }

        if requiresGlobalFallback {
            return .fullReconcile(rootPaths: nil)
        }

        if !fallbackRootPaths.isEmpty {
            return .fullReconcile(rootPaths: fallbackRootPaths.sorted())
        }

        if changedPaths.isEmpty {
            return .upToDate(baselineEventID: currentEventID)
        }

        return .refresh(paths: changedPaths.sorted(), cursorUpdates: cursorUpdates)
    }

    private func matchingRoot(for path: String) -> String? {
        rootPaths.first { path == $0 || path.hasPrefix($0 + "/") }
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
    private let lock = NSLock()

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    func eventID(for root: String) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return load()[key(for: root)]
    }

    func eventIDs(for roots: [String]) -> [String: UInt64] {
        lock.lock()
        defer { lock.unlock() }

        let cursors = load()
        var result: [String: UInt64] = [:]
        for root in roots {
            if let eventID = cursors[key(for: root)] {
                result[root] = eventID
            }
        }
        return result
    }

    func update(_ latestByRoot: [String: UInt64]) {
        guard !latestByRoot.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        var cursors = load()
        for (root, eventID) in latestByRoot {
            let key = key(for: root)
            cursors[key] = max(cursors[key] ?? 0, eventID)
        }
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

        var cursors = load()
        for root in roots {
            cursors.removeValue(forKey: key(for: root))
        }
        save(cursors)
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
