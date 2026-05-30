@testable import AllTheThings
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
}
