@testable import AllTheThings
import Foundation
import Testing

@Suite("Release updater")
struct ReleaseUpdaterTests {
    @Test("automatic updates prefer ZIP and retain DMG fallback")
    func automaticUpdatesPreferZip() {
        #expect(ReleaseUpdater.preferredAssetNameForTesting([
            "AllTheThings.dmg",
            "AllTheThings.tar.gz",
            "AllTheThings.zip"
        ]) == "AllTheThings.zip")
        #expect(ReleaseUpdater.preferredAssetNameForTesting([
            "AllTheThings.tar.gz",
            "AllTheThings.dmg"
        ]) == "AllTheThings.dmg")
    }

    @Test("DMG attach plist retains the mounted device identifier")
    func diskImageAttachPlistRetainsDeviceIdentifier() throws {
        let mountPoint = URL(fileURLWithPath: "/tmp/AllTheThings-Update-Test/mount", isDirectory: true)
        let plist = try plistString([
            "system-entities": [
                ["dev-entry": "/dev/disk42"],
                ["dev-entry": "/dev/disk42s1", "mount-point": mountPoint.path]
            ]
        ])

        let mounted = ReleaseUpdater.mountedDiskImageForTesting(
            attachPlist: plist,
            fallbackMountPoint: URL(fileURLWithPath: "/tmp/fallback", isDirectory: true)
        )
        #expect(mounted.deviceIdentifier == "/dev/disk42s1")
        #expect(mounted.mountPoint == mountPoint)
    }

    @Test("DMG cleanup retries normal detach without force")
    func diskImageCleanupRetriesWithoutForce() {
        let result = ReleaseUpdater.detachDiskImageForTesting(
            deviceIdentifier: "/dev/disk42s1",
            mountPoint: URL(fileURLWithPath: "/tmp/AllTheThings-Update-Test/mount", isDirectory: true),
            failuresBeforeSuccess: 2
        )

        #expect(result.succeeded)
        #expect(result.arguments.count == 3)
        #expect(result.arguments.allSatisfy { $0 == ["detach", "/dev/disk42s1", "-quiet"] })
        #expect(result.arguments.allSatisfy { !$0.contains("-force") })
    }

    @Test("stale mount cleanup only selects updater-owned temporary directories")
    func staleMountCleanupSelectionIsScoped() throws {
        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThings-Update-\(UUID().uuidString)", isDirectory: true)
        let mountPoint = workDirectory.appendingPathComponent("mount", isDirectory: true)
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: workDirectory)
        }

        let oldDate = Date().addingTimeInterval(-2 * 60 * 60)
        try fileManager.setAttributes(
            [.creationDate: oldDate, .modificationDate: oldDate],
            ofItemAtPath: workDirectory.path
        )

        #expect(ReleaseUpdater.staleUpdateWorkDirectoryForTesting(
            mountPoint: mountPoint,
            now: Date()
        ) == workDirectory.standardizedFileURL)
        #expect(ReleaseUpdater.staleUpdateWorkDirectoryForTesting(
            mountPoint: URL(fileURLWithPath: "/Volumes/AllTheThings", isDirectory: true),
            now: Date()
        ) == nil)
    }

    @Test("install helper moves on the same volume and keeps copy rollback")
    func installHelperContainsFastMoveAndCopyFallback() throws {
        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThings-Update-Helper-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: workDirectory)
        }

        let contents = try ReleaseUpdater.installHelperContentsForTesting(
            preparedAppURL: workDirectory.appendingPathComponent("New.app", isDirectory: true),
            currentAppURL: workDirectory.appendingPathComponent("Installed.app", isDirectory: true),
            workDirectory: workDirectory
        )

        #expect(contents.contains("/usr/bin/stat -f %d"))
        #expect(contents.contains("/bin/mv \"${new_app}\" \"${app_path}\""))
        #expect(contents.contains("/usr/bin/ditto \"${new_app}\" \"${app_path}\""))
        #expect(contents.contains("replacementDuration="))
        #expect(contents.contains("/bin/mv \"${backup_path}\" \"${app_path}\""))
        #expect(!contents.contains("-force"))
        _ = try ReleaseUpdater.runCommandForTesting(
            "/bin/zsh",
            arguments: ["-n", workDirectory.appendingPathComponent("install-update.zsh").path]
        )
    }

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

    private func plistString(_ value: Any) throws -> String {
        let data = try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .xml,
            options: 0
        )
        return String(decoding: data, as: UTF8.self)
    }
}
