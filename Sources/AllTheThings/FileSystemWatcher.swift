import CoreServices
import Foundation

struct FileSystemEvent {
    let path: String
    let flags: FSEventStreamEventFlags
    let eventID: FSEventStreamEventId

    var requiresRecursiveRescan: Bool {
        flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
            || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) != 0
            || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped) != 0
            || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
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
            sinceEventID(for: paths),
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

    private func sinceEventID(for roots: [String]) -> FSEventStreamEventId {
        let saved = roots.compactMap { cursorStore.eventID(for: $0) }
        guard saved.count == roots.count, let minimum = saved.min(), minimum > 0 else {
            return FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        }
        return FSEventStreamEventId(minimum)
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
