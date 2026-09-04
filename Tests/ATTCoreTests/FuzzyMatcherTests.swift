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
        let cppModule = try #require(makeRecord(name: "Module.cppm"))
        let hpp = try #require(makeRecord(name: "SearchIndex.hpp"))
        let ipp = try #require(makeRecord(name: "SearchIndex.ipp"))
        let swift = try #require(makeRecord(name: "SearchWindow.swift"))

        #expect(FuzzyMatcher.score(record: cpp, query: ".cpp") != nil)
        #expect(FuzzyMatcher.score(record: cppModule, query: ".cpp") == nil)
        #expect(FuzzyMatcher.score(record: swift, query: ".cpp") == nil)
        #expect(FuzzyMatcher.score(record: cpp, query: "*.cpp") != nil)
        #expect(FuzzyMatcher.score(record: swift, query: "*.cpp") == nil)
        #expect(FuzzyMatcher.score(record: cpp, query: "ext:cpp") != nil)
        #expect(FuzzyMatcher.score(record: cppModule, query: "ext:cpp") == nil)
        #expect(FuzzyMatcher.score(record: cppModule, query: "ext:cpp*") != nil)
        #expect(FuzzyMatcher.score(record: cpp, query: "*.[hic]pp") != nil)
        #expect(FuzzyMatcher.score(record: hpp, query: "*.[hic]pp") != nil)
        #expect(FuzzyMatcher.score(record: ipp, query: "*.[hic]pp") != nil)
        #expect(FuzzyMatcher.score(record: cppModule, query: "*.[hic]pp") == nil)
        #expect(FuzzyMatcher.score(record: hpp, query: "ext:[h-i]pp") != nil)
        #expect(FuzzyMatcher.score(record: ipp, query: "ext:[h-i]pp") != nil)
    }

    @Test("dotfile and compound extension queries preserve filename semantics")
    func dotfileAndCompoundExtensionQueries() throws {
        let gitignore = try #require(makeRecord(name: ".gitignore"))
        let zshrc = try #require(makeRecord(name: ".zshrc"))
        let archive = try #require(makeRecord(name: "backup.tar.gz"))
        let plainGzip = try #require(makeRecord(name: "backup.gz"))

        #expect(FuzzyMatcher.score(record: gitignore, query: ".gitignore") != nil)
        #expect(FuzzyMatcher.score(record: gitignore, query: "\".gitignore\"") != nil)
        #expect(FuzzyMatcher.score(record: zshrc, query: ".gitignore") == nil)
        #expect(FuzzyMatcher.score(record: archive, query: ".tar.gz") != nil)
        #expect(FuzzyMatcher.score(record: archive, query: "ext:tar.gz") != nil)
        #expect(FuzzyMatcher.score(record: plainGzip, query: "ext:tar.gz") == nil)
    }

    @Test("negative terms are literal and pure-negative queries include nonmatches")
    func literalAndPureNegativeTerms() throws {
        let notes = try #require(makeRecord(name: "text-notes.md"))
        let tests = try #require(makeRecord(name: "test-notes.md"))
        let package = try #require(makeRecord(name: "Package.swift", directory: "/tmp/project/Sources"))
        let dependency = try #require(makeRecord(name: "Package.swift", directory: "/tmp/project/node_modules"))

        #expect(FuzzyMatcher.score(record: notes, query: "notes -test") != nil)
        #expect(FuzzyMatcher.score(record: tests, query: "notes -test") == nil)
        #expect(FuzzyMatcher.score(record: package, query: "!node_modules") != nil)
        #expect(FuzzyMatcher.score(record: dependency, query: "!node_modules") == nil)
    }

    @Test("spaced alternatives and literal brackets remain searchable")
    func spacedAlternativesAndLiteralBrackets() throws {
        let foo = try #require(makeRecord(name: "foo.txt"))
        let bar = try #require(makeRecord(name: "bar.txt"))
        let neither = try #require(makeRecord(name: "quux.txt"))
        let bracketed = try #require(makeRecord(name: "report[1].pdf"))

        #expect(FuzzyMatcher.score(record: foo, query: "foo | bar") != nil)
        #expect(FuzzyMatcher.score(record: bar, query: "foo | bar") != nil)
        #expect(FuzzyMatcher.score(record: neither, query: "foo | bar") == nil)
        #expect(FuzzyMatcher.score(record: bracketed, query: "report[1].pdf") != nil)
    }

    @Test("normalization applies to non-ASCII extensions")
    func unicodeExtensionNormalization() throws {
        let record = try #require(makeRecord(name: "Résumé.RÉSUMÉ"))
        #expect(FuzzyMatcher.score(record: record, query: "ext:resume") != nil)
    }

    @Test("matches small typos")
    func typoMatch() throws {
        let record = try #require(makeRecord(name: "README.md"))
        let score = try #require(FuzzyMatcher.score(record: record, query: "redme"))
        #expect(score > 0)
    }

    @Test("calibrates short log matches")
    func shortLogMatchCalibration() throws {
        let arcology = try #require(makeRecord(name: "Arcology.md"))
        let yellowGlow = try #require(makeRecord(name: "YellowGlow.funhouse"))
        let colorGradient = try #require(makeRecord(name: "22_ColorGradient"))
        let klopfgeist = try #require(makeRecord(name: "#default.pst", directory: "/Applications/GarageBand.app/Contents/Resources/Plug-In Settings/Klopfgeist"))
        let alertCollector = try #require(makeRecord(name: "AlertCollector.strings", directory: "/Applications/GarageBand.app/Contents/Resources/ca.lproj"))

        let arcologyMatch = try #require(FuzzyMatcher.explain(record: arcology, query: "log"))
        #expect(arcologyMatch.matchClass == .substring)
        #expect(arcologyMatch.field == .name)

        #expect(FuzzyMatcher.explain(record: yellowGlow, query: "log")?.matchClass == .near)
        #expect(FuzzyMatcher.explain(record: colorGradient, query: "log")?.matchClass == .near)
        #expect(FuzzyMatcher.explain(record: klopfgeist, query: "log") == nil)
        #expect(FuzzyMatcher.explain(record: alertCollector, query: "log") == nil)
    }

    @Test("supports negative path tokens")
    func negativeToken() throws {
        let record = try #require(makeRecord(name: "Package.swift", directory: "/tmp/project/node_modules"))
        #expect(FuzzyMatcher.score(record: record, query: "package !node_modules") == nil)
    }

    @Test("plain text filters out unrelated paths")
    func plainTextDoesNotMatchScatteredPathCharacters() throws {
        let unrelated = try #require(makeRecord(name: "FETCH_HEAD", directory: "/Users/example/Documents/Workspace/embc/.git"))
        let projectPath = try #require(makeRecord(name: "artifacts", directory: "/Users/example/Documents/GitHub/AllTheThings", isDirectory: true))
        let matchingName = try #require(makeRecord(name: "UnitTests.swift", directory: "/Users/example/Documents/Workspace/embc/Sources"))
        let matchingPath = try #require(makeRecord(name: "Package.swift", directory: "/Users/example/Documents/Workspace/embc/Tests"))

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
        let application = try #require(makeRecord(name: "Safari.app", isDirectory: true))
        let file = try #require(makeRecord(name: "Sources.swift"))

        #expect(FuzzyMatcher.score(record: directory, query: "kind:folder") != nil)
        #expect(FuzzyMatcher.score(record: file, query: "kind:folder") == nil)
        #expect(FuzzyMatcher.score(record: application, query: "kind:app") != nil)
        #expect(FuzzyMatcher.score(record: application, query: "type:application") != nil)
        #expect(FuzzyMatcher.score(record: directory, query: "kind:app") == nil)
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
            directory: "/Users/example/Documents/Workspace/containers/source/gct/strings"
        ))

        #expect(FuzzyMatcher.score(record: record, query: "source/**/*.hpp") != nil)
        #expect(FuzzyMatcher.score(record: record, query: "**/gct/**/fuzzy*.hpp") != nil)
        #expect(FuzzyMatcher.score(record: record, query: "source/*.hpp") == nil)
        #expect(FuzzyMatcher.score(record: record, query: "**/gct/*.hpp") == nil)
    }

    @Test("expands the current user home shorthand in path queries")
    func homeDirectoryShorthand() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let record = try #require(makeRecord(
            name: "manifest.json",
            directory: "\(home)/Projects/atlas-engine/Sources"
        ))
        let outsideHome = try #require(makeRecord(
            name: "manifest.json",
            directory: "/Library/Projects/atlas-engine/Sources"
        ))

        #expect(FuzzyMatcher.score(record: record, query: "~") != nil)
        #expect(FuzzyMatcher.score(record: record, query: "~/Projects") != nil)
        #expect(FuzzyMatcher.score(record: record, query: "~/Projects/**/manifest.json") != nil)
        #expect(FuzzyMatcher.score(record: outsideHome, query: "~/Projects/**/manifest.json") == nil)
    }

    @Test("exact literal path components outrank fuzzy prefixes around wildcards")
    func exactWildcardPathComponentsOutrankFuzzyPrefixes() throws {
        let exact = try #require(makeRecord(
            name: "manifest.json",
            directory: "/Users/example/Projects/atlas-engine/Sources"
        ))
        let fuzzyPrefix = try #require(makeRecord(
            name: "manifest.json",
            directory: "/Users/example/Projects/atlas-engine-cache/Sources"
        ))
        let query = "/Users/example/Projects/atlas-engine/**/manifest.json"

        let exactMatch = try #require(FuzzyMatcher.explain(record: exact, query: query))
        let fuzzyPrefixMatch = try #require(FuzzyMatcher.explain(record: fuzzyPrefix, query: query))

        #expect(exactMatch.quality > fuzzyPrefixMatch.quality)
        #expect(exactMatch.score > fuzzyPrefixMatch.score)
    }

    @Test("supports slash-structured path prefixes")
    func slashStructuredPathPrefixes() throws {
        let record = try #require(makeRecord(
            name: "fuzzy_match.hpp",
            directory: "/Users/example/Documents/Workspace/containers/source/gct/strings"
        ))

        #expect(FuzzyMatcher.score(
            record: record,
            query: "/Users/exa/Doc/Wor/cont/source/gct/str/fuzzy"
        ) != nil)
        #expect(FuzzyMatcher.score(
            record: record,
            query: "/Users/example/Documents/Workspace/source/containers"
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
            fileExtension: FuzzyMatcher.normalize(url.pathExtension),
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
