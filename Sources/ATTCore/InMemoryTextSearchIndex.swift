import Foundation

/// A compact candidate index for small, mutable collections of user-facing text.
/// It shares gram encoding and posting-list intersection with the file index, then
/// verifies candidates with the same normalization and fuzzy subsequence scoring.
public struct InMemoryTextSearchIndex: Equatable, Sendable {
    private let normalizedTexts: [String]
    private let bytePostings: [Int: [Int32]]

    public init(texts: [String]) {
        normalizedTexts = texts.map(FuzzyMatcher.normalize)

        var postings: [Int: [Int32]] = [:]
        for (index, text) in normalizedTexts.enumerated() {
            guard let storedIndex = Int32(exactly: index) else { break }
            for byte in Set(text.utf8) {
                let key = SearchTextGrams.key(bytes: [byte], start: 0, length: 1)
                postings[key, default: []].append(storedIndex)
            }
        }
        bytePostings = postings
    }

    public func matchingIndices(for query: String) -> [Int] {
        let normalizedQuery = FuzzyMatcher.normalize(
            query.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !normalizedQuery.isEmpty else { return Array(normalizedTexts.indices) }

        let keys = Set(normalizedQuery.utf8).map {
            SearchTextGrams.key(bytes: [$0], start: 0, length: 1)
        }
        var postings = keys.compactMap { bytePostings[$0] }
        guard postings.count == keys.count,
              !postings.isEmpty else {
            return []
        }
        postings.sort { $0.count < $1.count }
        guard let candidates = SortedPostingLists.intersection(postings) else { return [] }

        return candidates.compactMap { candidate in
            let index = Int(candidate)
            guard normalizedTexts.indices.contains(index),
                  FuzzyMatcher.scoreNormalizedText(
                      normalizedTexts[index],
                      matching: normalizedQuery
                  ) != nil else {
                return nil
            }
            return index
        }
    }
}

enum SearchTextGrams {
    static func collectKeys(from text: String, into keys: inout Set<Int>) {
        guard !text.isEmpty else { return }
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return }

        for length in 1...min(3, bytes.count) {
            let lastStart = bytes.count - length
            for start in 0...lastStart {
                keys.insert(key(bytes: bytes, start: start, length: length))
            }
        }
    }

    static func queryKeys(for tokenBytes: [UInt8]) -> [Int] {
        guard !tokenBytes.isEmpty else { return [] }
        if tokenBytes.count <= 3 {
            return [key(bytes: tokenBytes, start: 0, length: tokenBytes.count)]
        }

        var keys = Set<Int>()
        for start in 0...(tokenBytes.count - 3) {
            keys.insert(key(bytes: tokenBytes, start: start, length: 3))
        }
        return Array(keys)
    }

    static func key(bytes: [UInt8], start: Int, length: Int) -> Int {
        var key = length << 24
        for offset in 0..<length {
            key |= Int(bytes[start + offset]) << ((2 - offset) * 8)
        }
        return key
    }
}

enum SortedPostingLists {
    static func intersection(
        _ postings: [[Int32]],
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> [Int32]? {
        guard var result = postings.first else { return [] }

        for posting in postings.dropFirst() {
            guard !shouldCancel() else { return nil }
            guard let next = intersection(result, posting, shouldCancel: shouldCancel) else {
                return nil
            }
            result = next
            if result.isEmpty { break }
        }
        return result
    }

    static func intersection(
        _ lhs: [Int32],
        _ rhs: [Int32],
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> [Int32]? {
        var result: [Int32] = []
        result.reserveCapacity(min(lhs.count, rhs.count))

        var leftIndex = 0
        var rightIndex = 0
        var comparisonCount = 0
        while leftIndex < lhs.count, rightIndex < rhs.count {
            if comparisonCount & 255 == 0, shouldCancel() { return nil }
            comparisonCount += 1

            let left = lhs[leftIndex]
            let right = rhs[rightIndex]
            if left == right {
                result.append(left)
                leftIndex += 1
                rightIndex += 1
            } else if left < right {
                leftIndex += 1
            } else {
                rightIndex += 1
            }
        }
        return result
    }
}
