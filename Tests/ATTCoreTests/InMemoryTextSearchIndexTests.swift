@testable import ATTCore
import Testing

@Suite("In-memory text search index")
struct InMemoryTextSearchIndexTests {
    @Test("indexed candidates preserve normalized fuzzy subsequence matches")
    func indexedCandidatesPreserveNormalizedFuzzySubsequenceMatches() {
        let index = InMemoryTextSearchIndex(texts: [
            "README ext:md",
            "kind:folder project",
            "Résumé notes",
            "release checklist"
        ])

        #expect(index.matchingIndices(for: "rdme") == [0])
        #expect(index.matchingIndices(for: "resume") == [2])
        #expect(index.matchingIndices(for: "rck") == [3])
        #expect(index.matchingIndices(for: "missing") == [])
    }

    @Test("empty indexed query preserves source order")
    func emptyIndexedQueryPreservesSourceOrder() {
        let index = InMemoryTextSearchIndex(texts: ["third", "first", "second"])

        #expect(index.matchingIndices(for: "") == [0, 1, 2])
        #expect(index.matchingIndices(for: "   ") == [0, 1, 2])
    }

    @Test("selective lookup stays correct across a large history")
    func selectiveLookupAcrossLargeHistory() {
        var texts = (0..<20_000).map { "ordinary-query-\($0)" }
        texts.append("special-zyxwv-target")
        let index = InMemoryTextSearchIndex(texts: texts)

        #expect(index.matchingIndices(for: "zyxwv") == [20_000])
    }
}
