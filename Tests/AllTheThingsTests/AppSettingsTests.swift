@testable import AllTheThings
import Foundation
import Testing

@Suite("App settings")
struct AppSettingsTests {
    @Test("reading unconfigured indexed roots does not persist defaults")
    func readingUnconfiguredIndexedRootsDoesNotPersistDefaults() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        AppSettings.registerDefaults(defaults)

        #expect(!AppSettings.indexedRootsConfigured(defaults: defaults))
        #expect(AppSettings.indexedRoots(defaults: defaults).isEmpty)
        #expect(!AppSettings.indexedRootsConfigured(defaults: defaults))
        #expect(defaults.object(forKey: AppSettings.indexedRootsKey) == nil)
        #expect(defaults.object(forKey: AppSettings.indexedRootsInitializedKey) == nil)
    }

    @Test("saving indexed roots marks indexing configured")
    func savingIndexedRootsMarksIndexingConfigured() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let root = URL(fileURLWithPath: "/tmp/AllTheThingsTests", isDirectory: true)
        AppSettings.saveIndexedRoots([root], defaults: defaults)

        #expect(AppSettings.indexedRootsConfigured(defaults: defaults))
        #expect(AppSettings.indexedRoots(defaults: defaults) == [root.standardizedFileURL])
    }

    @Test("empty saved roots still represent an explicit configured state")
    func emptySavedRootsStillRepresentExplicitConfiguredState() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        AppSettings.saveIndexedRoots([], defaults: defaults)

        #expect(AppSettings.indexedRootsConfigured(defaults: defaults))
        #expect(AppSettings.indexedRoots(defaults: defaults).isEmpty)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "AllTheThingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
