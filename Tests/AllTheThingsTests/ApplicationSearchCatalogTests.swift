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

    @Test("metadata aliases classify by matched shape and rank vscode before xcode")
    func metadataAliasesClassifyByMatchedShapeAndRankVSCodeBeforeXcode() throws {
        let fixture = try AppCatalogFixture()
        defer { fixture.remove() }

        _ = try fixture.makeApp("Xcode.app", infoPlist: [
            "CFBundleIdentifier": "com.apple.dt.Xcode",
            "CFBundleName": "Xcode",
            "CFBundleExecutable": "Xcode"
        ])
        _ = try fixture.makeApp("Visual Studio Code.app", infoPlist: [
            "CFBundleIdentifier": "com.microsoft.VSCode",
            "CFBundleURLTypes": [[
                "CFBundleURLName": "Visual Studio Code",
                "CFBundleURLSchemes": ["vscode"]
            ]],
            "CFBundleDisplayName": "Code",
            "CFBundleName": "Code",
            "CFBundleExecutable": "Code"
        ])
        _ = try fixture.makeApp("My VSCode Helper.app")

        let vscodeResponse = try #require(ApplicationSearchCatalog().search(
            queryText: "vscode",
            roots: [fixture.root],
            sort: SortSpec(column: .name, ascending: true),
            maxResults: 100
        ))
        #expect(vscodeResponse.results.first?.record.name == "Visual Studio Code.app")
        #expect(vscodeResponse.results.first?.match?.matchClass == .exact)
        #expect(vscodeResponse.results.first?.match?.isAliasDerived == true)
        let helperResult = try #require(vscodeResponse.results.first { $0.record.name == "My VSCode Helper.app" })
        #expect(helperResult.match?.matchClass == .substring)
        #expect(helperResult.match?.isAliasDerived == false)

        let compactAliasResponse = try #require(ApplicationSearchCatalog().search(
            queryText: "vsc",
            roots: [fixture.root],
            sort: SortSpec(column: .name, ascending: true),
            maxResults: 100
        ))
        #expect(compactAliasResponse.results.first?.record.name == "Visual Studio Code.app")
        #expect(compactAliasResponse.results.first?.match?.matchClass == .exact)
        #expect(compactAliasResponse.results.first?.match?.isAliasDerived == true)

        let xcodeResponse = try #require(ApplicationSearchCatalog().search(
            queryText: "xcode",
            roots: [fixture.root],
            sort: SortSpec(column: .name, ascending: true),
            maxResults: 100
        ))
        #expect(xcodeResponse.results.first?.record.name == "Xcode.app")
        #expect(xcodeResponse.results.first?.match?.matchClass == .exact)
        #expect(xcodeResponse.results.first?.match?.isAliasDerived == false)
    }

    @Test("app basename exact and prefix matches beat metadata alias prefixes")
    func appBasenameExactAndPrefixMatchesBeatMetadataAliasPrefixes() throws {
        let fixture = try AppCatalogFixture()
        defer { fixture.remove() }

        _ = try fixture.makeApp("VLC.app", infoPlist: [
            "CFBundleIdentifier": "org.videolan.vlc",
            "CFBundleName": "VLC",
            "CFBundleExecutable": "VLC",
            "CFBundleURLTypes": [[
                "CFBundleURLName": "VLC",
                "CFBundleURLSchemes": ["vlc"]
            ]]
        ])
        _ = try fixture.makeApp("Steam.app", infoPlist: [
            "CFBundleIdentifier": "com.valvesoftware.Steam",
            "CFBundleName": "Steam",
            "CFBundleExecutable": "Steam",
            "CFBundleURLTypes": [[
                "CFBundleURLName": "Valve",
                "CFBundleURLSchemes": ["valve"]
            ]]
        ])
        _ = try fixture.makeApp("Preview.app")

        let response = try #require(ApplicationSearchCatalog().search(
            queryText: "VLC",
            roots: [fixture.root],
            sort: SortSpec(column: .name, ascending: true),
            maxResults: 100
        ))

        #expect(response.results.first?.record.name == "VLC.app")
        #expect(response.results.first?.match?.matchClass == .exact)
        #expect(response.results.first?.match?.isAliasDerived == false)

        let prefixResponse = try #require(ApplicationSearchCatalog().search(
            queryText: "v",
            roots: [fixture.root],
            sort: SortSpec(column: .name, ascending: true),
            maxResults: 100
        ))

        #expect(prefixResponse.results.first?.record.name == "VLC.app")
        #expect(prefixResponse.results.first?.match?.matchClass == .prefix)
        #expect(prefixResponse.results.first?.match?.isAliasDerived == false)
        let steamIndex = try #require(prefixResponse.results.firstIndex { $0.record.name == "Steam.app" })
        let previewIndex = try #require(prefixResponse.results.firstIndex { $0.record.name == "Preview.app" })
        let steamResult = prefixResponse.results[steamIndex]
        let previewResult = prefixResponse.results[previewIndex]
        #expect(steamResult.match?.matchClass == .prefix)
        #expect(steamResult.match?.isAliasDerived == true)
        #expect(previewResult.match?.matchClass == .substring)
        #expect(steamIndex > 0)
        #expect(steamIndex < previewIndex)
    }

    @Test("exact app name matches beat exact metadata alias matches")
    func exactAppNameMatchesBeatExactMetadataAliasMatches() throws {
        let fixture = try AppCatalogFixture()
        defer { fixture.remove() }

        _ = try fixture.makeApp("Claude Code Link Helper.app", infoPlist: [
            "CFBundleIdentifier": "com.anthropic.claude-code-link-helper",
            "CFBundleName": "Claude Code Link Helper",
            "CFBundleExecutable": "Claude Code Link Helper"
        ])
        _ = try fixture.makeApp("Claude.app")

        let response = try #require(ApplicationSearchCatalog().search(
            queryText: "claude",
            roots: [fixture.root],
            sort: SortSpec(column: .name, ascending: true),
            maxResults: 100
        ))

        #expect(response.results.first?.record.name == "Claude.app")
        #expect(response.results.first?.match?.matchClass == .exact)
        #expect(response.results.first?.match?.isAliasDerived == false)
        let helperResult = try #require(response.results.first { $0.record.name == "Claude Code Link Helper.app" })
        #expect(helperResult.match?.matchClass == .exact)
        #expect(helperResult.match?.isAliasDerived == true)
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

    @Test("cancelled recursive scan does not publish app cache")
    func cancelledRecursiveScanDoesNotPublishAppCache() throws {
        let fixture = try AppCatalogFixture()
        defer { fixture.remove() }

        for index in 0..<8 {
            try fixture.makeDirectory("Folder\(index)/Nested\(index)")
        }

        let catalog = ApplicationSearchCatalog()
        var cancelChecks = 0
        let cancelled = catalog.search(
            queryText: "",
            roots: [fixture.root],
            sort: SortSpec(column: .name, ascending: true),
            maxResults: 100
        ) {
            cancelChecks += 1
            return cancelChecks >= 3
        }

        #expect(cancelled == nil)
        #expect(cancelChecks >= 3)

        _ = try fixture.makeApp("Later.app")
        let response = try #require(catalog.search(
            queryText: "",
            roots: [fixture.root],
            sort: SortSpec(column: .name, ascending: true),
            maxResults: 100
        ))
        #expect(response.results.map(\.record.name) == ["Later.app"])
    }

    @Test("application root events invalidate a cached catalog")
    func applicationRootEventsInvalidateCachedCatalog() throws {
        let fixture = try AppCatalogFixture()
        defer { fixture.remove() }

        let catalog = ApplicationSearchCatalog()
        let initial = try #require(catalog.search(
            queryText: "",
            roots: [fixture.root],
            sort: SortSpec(column: .name, ascending: true),
            maxResults: 100
        ))
        #expect(initial.results.isEmpty)

        let installedApp = try fixture.makeApp("NewlyInstalled.app")
        let events = [FileSystemEvent(path: installedApp.path, flags: 0, eventID: 1)]
        #expect(ApplicationSearchEventFilter.shouldInvalidate(events: events, roots: [fixture.root]))

        catalog.invalidate()
        let refreshed = try #require(catalog.search(
            queryText: "",
            roots: [fixture.root],
            sort: SortSpec(column: .name, ascending: true),
            maxResults: 100
        ))
        #expect(refreshed.results.map(\.record.name) == ["NewlyInstalled.app"])

        let unrelated = [FileSystemEvent(path: "/tmp/Elsewhere/App.app", flags: 0, eventID: 2)]
        #expect(!ApplicationSearchEventFilter.shouldInvalidate(events: unrelated, roots: [fixture.root]))
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

    func makeApp(_ relativePath: String, infoPlist: [String: Any]? = nil) throws -> URL {
        let app = root.appendingPathComponent(relativePath, isDirectory: true)
        try makeDirectory(relativePath)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try fileManager.createDirectory(at: contents, withIntermediateDirectories: true)

        if let infoPlist {
            let data = try PropertyListSerialization.data(
                fromPropertyList: infoPlist,
                format: .xml,
                options: 0
            )
            try data.write(to: contents.appendingPathComponent("Info.plist", isDirectory: false))
        }

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
