import CoreServices
import Foundation

final class FileSystemWatcher {
    private let queue = DispatchQueue(label: "att.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?
    private var eventHandler: (@MainActor @Sendable ([String]) -> Void)?

    deinit {
        stop()
    }

    func start(roots: [URL], eventHandler: @escaping @MainActor @Sendable ([String]) -> Void) {
        stop()

        let paths = roots.map { $0.standardizedFileURL.path }
        guard !paths.isEmpty else { return }

        self.eventHandler = eventHandler

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            watcher.handle(paths: Array(paths.prefix(eventCount)))
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
    }

    private func handle(paths: [String]) {
        guard !paths.isEmpty else { return }
        guard let eventHandler else { return }

        Task { @MainActor in
            eventHandler(paths)
        }
    }
}
