import ATTCore
import Foundation
import Testing

@Suite("Fuzzy matcher")
struct FuzzyMatcherTests {
    @Test("matches acronyms across filename boundaries")
    func acronymMatch() throws {
        let record = try #require(makeRecord(name: "PhotoSyncReport.final.pdf"))
        let score = try #require(FuzzyMatcher.score(record: record, query: "psr"))
        #expect(score > 0)
    }

    @Test("matches extension-leading queries")
    func extensionMatch() throws {
        let cpp = try #require(makeRecord(name: "SearchIndex.cpp"))
        let swift = try #require(makeRecord(name: "SearchWindow.swift"))

        #expect(FuzzyMatcher.score(record: cpp, query: ".cpp") != nil)
        #expect(FuzzyMatcher.score(record: swift, query: ".cpp") == nil)
        #expect(FuzzyMatcher.score(record: cpp, query: "*.cpp") != nil)
        #expect(FuzzyMatcher.score(record: swift, query: "*.cpp") == nil)
    }

    @Test("matches small typos")
    func typoMatch() throws {
        let record = try #require(makeRecord(name: "README.md"))
        let score = try #require(FuzzyMatcher.score(record: record, query: "redme"))
        #expect(score > 0)
    }

    @Test("supports negative path tokens")
    func negativeToken() throws {
        let record = try #require(makeRecord(name: "Package.swift", directory: "/tmp/project/node_modules"))
        #expect(FuzzyMatcher.score(record: record, query: "package !node_modules") == nil)
    }

    @Test("plain text filters out unrelated paths")
    func plainTextDoesNotMatchScatteredPathCharacters() throws {
        let unrelated = try #require(makeRecord(name: "FETCH_HEAD", directory: "/Users/jaeger/Documents/Personal/embc/.git"))
        let projectPath = try #require(makeRecord(name: "artifacts", directory: "/Users/jaeger/Documents/GitHub/AllTheThings", isDirectory: true))
        let matchingName = try #require(makeRecord(name: "UnitTests.swift", directory: "/Users/jaeger/Documents/Personal/embc/Sources"))
        let matchingPath = try #require(makeRecord(name: "Package.swift", directory: "/Users/jaeger/Documents/Personal/embc/Tests"))

        #expect(FuzzyMatcher.score(record: unrelated, query: "test") == nil)
        #expect(FuzzyMatcher.score(record: projectPath, query: "test") == nil)
        #expect(FuzzyMatcher.score(record: matchingName, query: "test") != nil)
        #expect(FuzzyMatcher.score(record: matchingPath, query: "test") != nil)
    }

    @Test("supports fielded fuzzy clauses")
    func fieldedFuzzyClauses() throws {
        let source = try #require(makeRecord(name: "SearchWindowController.swift", directory: "/tmp/project/Sources/AllTheThings"))
        let test = try #require(makeRecord(name: "SearchWindowController.swift", directory: "/tmp/project/Tests/AllTheThings"))

        let score = try #require(FuzzyMatcher.score(record: source, query: "name:swc path:Sources ext:swift"))
        #expect(score > 0)
        #expect(FuzzyMatcher.score(record: test, query: "name:swc path:Sources ext:swift") == nil)
    }

    @Test("supports extension alternatives")
    func extensionAlternatives() throws {
        let swift = try #require(makeRecord(name: "SearchWindow.swift"))
        let markdown = try #require(makeRecord(name: "README.md"))
        let pdf = try #require(makeRecord(name: "Manual.pdf"))

        #expect(FuzzyMatcher.score(record: swift, query: "ext:swift|md") != nil)
        #expect(FuzzyMatcher.score(record: markdown, query: "ext:swift|md") != nil)
        #expect(FuzzyMatcher.score(record: pdf, query: "ext:swift|md") == nil)
    }

    @Test("supports kind filters")
    func kindFilters() throws {
        let directory = try #require(makeRecord(name: "Sources", isDirectory: true))
        let file = try #require(makeRecord(name: "Sources.swift"))

        #expect(FuzzyMatcher.score(record: directory, query: "kind:folder") != nil)
        #expect(FuzzyMatcher.score(record: file, query: "kind:folder") == nil)
        #expect(FuzzyMatcher.score(record: file, query: "type:file") != nil)
    }

    @Test("supports wildcard clauses")
    func wildcardClauses() throws {
        let match = try #require(makeRecord(name: "SearchWindow.swift"))
        let miss = try #require(makeRecord(name: "WindowSearch.swift"))

        #expect(FuzzyMatcher.score(record: match, query: "name:Search*.swift") != nil)
        #expect(FuzzyMatcher.score(record: miss, query: "name:Search*.swift") == nil)
    }

    @Test("supports Ant-style path wildcards")
    func antStylePathWildcards() throws {
        let record = try #require(makeRecord(
            name: "fuzzy_match.hpp",
            directory: "/Users/jaeger/Documents/Personal/containers/source/gct/strings"
        ))

        #expect(FuzzyMatcher.score(record: record, query: "source/**/*.hpp") != nil)
        #expect(FuzzyMatcher.score(record: record, query: "**/gct/**/fuzzy*.hpp") != nil)
        #expect(FuzzyMatcher.score(record: record, query: "source/*.hpp") == nil)
        #expect(FuzzyMatcher.score(record: record, query: "**/gct/*.hpp") == nil)
    }

    @Test("supports slash-structured path prefixes")
    func slashStructuredPathPrefixes() throws {
        let record = try #require(makeRecord(
            name: "fuzzy_match.hpp",
            directory: "/Users/jaeger/Documents/Personal/containers/source/gct/strings"
        ))

        #expect(FuzzyMatcher.score(
            record: record,
            query: "/Users/jae/Doc/Per/cont/source/gct/str/fuzzy"
        ) != nil)
        #expect(FuzzyMatcher.score(
            record: record,
            query: "/Users/jaeger/Documents/Personal/source/containers"
        ) == nil)
    }

    @Test("supports wildcard extension filters")
    func wildcardExtensionFilters() throws {
        let cpp = try #require(makeRecord(name: "SearchIndex.cpp"))
        let swift = try #require(makeRecord(name: "SearchWindow.swift"))

        #expect(FuzzyMatcher.score(record: cpp, query: "ext:*.cpp") != nil)
        #expect(FuzzyMatcher.score(record: swift, query: "ext:*.cpp") == nil)
    }

    @Test("supports structured negative clauses")
    func structuredNegativeClauses() throws {
        let dependency = try #require(makeRecord(name: "Package.swift", directory: "/tmp/project/node_modules"))
        let source = try #require(makeRecord(name: "Package.swift", directory: "/tmp/project/Sources"))

        #expect(FuzzyMatcher.score(record: dependency, query: "package !path:node_modules") == nil)
        #expect(FuzzyMatcher.score(record: source, query: "package !path:node_modules") != nil)
    }

    private func makeRecord(name: String, directory: String = "/tmp/project", isDirectory: Bool = false) -> FileRecord? {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        let normalizedName = FuzzyMatcher.normalize(name)
        let normalizedPath = FuzzyMatcher.normalize(url.path)

        return FileRecord(
            id: FileRecord.stableID(for: url.path),
            path: url.path,
            name: name,
            directoryPath: directory,
            fileExtension: url.pathExtension.lowercased(),
            sizeBytes: 128,
            modifiedTime: Date().timeIntervalSinceReferenceDate,
            createdTime: nil,
            isDirectory: isDirectory,
            isHidden: name.hasPrefix("."),
            volumeName: "Test",
            normalizedName: normalizedName,
            normalizedPath: normalizedPath
        )
    }
}
