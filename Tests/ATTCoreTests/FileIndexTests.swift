import ATTCore
import Foundation
import Testing

@Suite("File index")
struct FileIndexTests {
    @Test("refresh moves an updated file to the top of modified sort")
    func refreshResortsModifiedResults() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let olderFile = root.appendingPathComponent("older.txt")
        let newerFile = root.appendingPathComponent("newer.txt")
        try "older".write(to: olderFile, atomically: true, encoding: .utf8)
        try "newer".write(to: newerFile, atomically: true, encoding: .utf8)

        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = Date(timeIntervalSince1970: 1_700_000_100)
        try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: olderFile.path)
        try fileManager.setAttributes([.modificationDate: newDate], ofItemAtPath: newerFile.path)
        try fileManager.setAttributes([.modificationDate: oldDate.addingTimeInterval(-100)], ofItemAtPath: root.path)

        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)")
        index.replaceRootsAndRebuild([root])

        try await waitUntil {
            let stats = index.currentStats()
            return !stats.isIndexing && stats.indexedCount >= 3
        }

        var response = index.search(SearchRequest(
            query: "",
            sort: SortSpec(column: .modified, ascending: false)
        ), maxResults: 5)
        #expect(response.results.first?.record.path == newerFile.path)

        let newestDate = Date(timeIntervalSince1970: 1_700_000_200)
        try fileManager.setAttributes([.modificationDate: newestDate], ofItemAtPath: olderFile.path)
        index.refresh(paths: [olderFile.path])

        try await waitUntil {
            response = index.search(SearchRequest(
                query: "",
                sort: SortSpec(column: .modified, ascending: false)
            ), maxResults: 5)
            return response.results.first?.record.path == olderFile.path
        }

        let refreshedModifiedTime = try #require(response.results.first?.record.modifiedTime)
        #expect(abs(refreshedModifiedTime - newestDate.timeIntervalSinceReferenceDate) < 0.001)
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        pollInterval: Duration = .milliseconds(25),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout

        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: pollInterval)
        }

        Issue.record("Timed out waiting for condition")
    }
}
