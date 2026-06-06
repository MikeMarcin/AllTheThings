@testable import AllTheThings
import ATTCore
import Foundation
import Testing

@Suite("Application search catalog")
struct ApplicationSearchCatalogTests {
    @Test("parses app scoped queries")
    func parsesAppScopedQueries() throws {
        #expect(ApplicationSearchQuery.parse("app:")?.searchText == "")
        #expect(ApplicationSearchQuery.parse("app:Safari")?.searchText == "Safari")
        #expect(ApplicationSearchQuery.parse(" applications:  Terminal ")?.searchText == "Terminal")
        #expect(ApplicationSearchQuery.parse("Safari") == nil)
        #expect(ApplicationSearchQuery.parse("name:Safari") == nil)
    }

    @Test("recursive scan finds app bundles and skips bundle internals")
    func recursiveScanFindsAppBundlesAndSkipsBundleInternals() throws {
        let fixture = try AppCatalogFixture()
        defer { fixture.remove() }

        _ = try fixture.makeApp("Calculator.app")
        _ = try fixture.makeApp("Utilities/Terminal.app")
        try fixture.makeDirectory("Calculator.app/Contents/NestedHelper.app")
        try fixture.makeDirectory("Notes")

        let response = try #require(ApplicationSearchCatalog().search(
            queryText: "",
            roots: [fixture.root],
            sort: SortSpec(column: .name, ascending: true),
            maxResults: 100
        ))
        let names = response.results.map(\.record.name)

        #expect(names == ["Calculator.app", "Terminal.app"])
        #expect(!names.contains("NestedHelper.app"))
        #expect(response.executionProfile.executionPath == .applicationCatalog)
        #expect(response.executionProfile.indexesUsed == [.applicationCatalog])
    }

    @Test("search text filters apps only")
    func searchTextFiltersAppsOnly() throws {
        let fixture = try AppCatalogFixture()
        defer { fixture.remove() }

        _ = try fixture.makeApp("Calculator.app")
        _ = try fixture.makeApp("Terminal.app")

        let response = try #require(ApplicationSearchCatalog().search(
            queryText: "term",
            roots: [fixture.root],
            sort: SortSpec(column: .name, ascending: true),
            maxResults: 100
        ))

        #expect(response.results.map(\.record.name) == ["Terminal.app"])
        #expect(response.totalMatches == 1)
        #expect(response.results.first?.match != nil)
    }

    @Test("configured app bundle root is searchable")
    func configuredAppBundleRootIsSearchable() throws {
        let fixture = try AppCatalogFixture()
        defer { fixture.remove() }

        let app = try fixture.makeApp("Direct.app")
        let response = try #require(ApplicationSearchCatalog().search(
            queryText: "",
            roots: [app],
            sort: SortSpec(column: .name, ascending: true),
            maxResults: 100
        ))

        #expect(response.results.map(\.record.name) == ["Direct.app"])
        #expect(response.results.first?.rootPath == app.path)
    }
}

private struct AppCatalogFixture {
    let root: URL
    private let fileManager = FileManager.default

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AllTheThings-AppCatalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeApp(_ relativePath: String) throws -> URL {
        let app = root.appendingPathComponent(relativePath, isDirectory: true)
        try makeDirectory(relativePath)
        try fileManager.createDirectory(
            at: app.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        return app
    }

    func makeDirectory(_ relativePath: String) throws {
        try fileManager.createDirectory(
            at: root.appendingPathComponent(relativePath, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? fileManager.removeItem(at: root)
    }
}
