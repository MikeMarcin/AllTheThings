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

    private func makeRecord(name: String, directory: String = "/tmp/project") -> FileRecord? {
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
            isDirectory: false,
            isHidden: name.hasPrefix("."),
            volumeName: "Test",
            normalizedName: normalizedName,
            normalizedPath: normalizedPath
        )
    }
}
