@testable import AllTheThings
import Foundation
import Testing

@Suite("Release updater")
struct ReleaseUpdaterTests {
    @Test("command runner drains large stdout and stderr")
    func commandRunnerDrainsLargeStdoutAndStderr() throws {
        let script = """
        for i in {1..6000}; do
          print -r -- "stdout-${i}-abcdefghijklmnopqrstuvwxyz"
          print -ru2 -- "stderr-${i}-abcdefghijklmnopqrstuvwxyz"
        done
        """

        let output = try ReleaseUpdater.runCommandForTesting("/bin/zsh", arguments: ["-c", script])

        #expect(output.contains("stdout-6000-abcdefghijklmnopqrstuvwxyz"))
        #expect(output.contains("stderr-6000-abcdefghijklmnopqrstuvwxyz"))
    }

    @Test("failed download removes update work directory")
    func failedDownloadRemovesUpdateWorkDirectory() async throws {
        let fileManager = FileManager.default
        let temporaryPayload = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThings-Update-Payload-\(UUID().uuidString)", isDirectory: false)
        try "payload".write(to: temporaryPayload, atomically: true, encoding: .utf8)
        defer {
            try? fileManager.removeItem(at: temporaryPayload)
        }

        let downloadURL = try #require(URL(string: "https://example.test/AllTheThings.zip"))
        let response = try #require(HTTPURLResponse(
            url: downloadURL,
            statusCode: 500,
            httpVersion: nil,
            headerFields: nil
        ))
        let before = updateWorkDirectories()

        do {
            _ = try await ReleaseUpdater.downloadForTesting(
                assetName: "AllTheThings.zip",
                downloadURL: downloadURL
            ) { _ in
                (temporaryPayload, response)
            }
            Issue.record("Expected failed download to throw")
        } catch {
            // Expected path.
        }

        let after = updateWorkDirectories()
        #expect(after.subtracting(before).isEmpty)
    }

    private func updateWorkDirectories() -> Set<String> {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
        let contents = (try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return Set(contents
            .filter { $0.lastPathComponent.hasPrefix("AllTheThings-Update-") }
            .map(\.path))
    }
}
