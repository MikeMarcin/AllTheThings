import Foundation

public enum FuzzyMatcher {
    public struct ParsedQuery: Sendable {
        let positive: [QueryPart]
        let negative: [String]

        var isEmpty: Bool {
            positive.isEmpty && negative.isEmpty
        }
    }

    enum QueryPart: Sendable {
        case fuzzy(String)
        case exact(String)
        case fileExtension(String)
    }

    public static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    public static func parse(_ query: String) -> ParsedQuery {
        let rawParts = splitQuery(query)
        var positives: [QueryPart] = []
        var negatives: [String] = []

        for raw in rawParts {
            let isNegative = raw.hasPrefix("!") && raw.count > 1
            let value = isNegative ? String(raw.dropFirst()) : raw
            let normalized = normalize(value.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !normalized.isEmpty else { continue }

            if isNegative {
                negatives.append(normalized)
            } else if normalized.hasPrefix(".") && normalized.count > 1 {
                positives.append(.fileExtension(String(normalized.dropFirst())))
            } else if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count > 1 {
                positives.append(.exact(String(normalized.dropFirst().dropLast())))
            } else {
                positives.append(.fuzzy(normalized))
            }
        }

        return ParsedQuery(positive: positives, negative: negatives)
    }

    public static func score(record: FileRecord, query: String) -> Int? {
        let parsed = parse(query)
        guard !parsed.isEmpty else { return 0 }

        for negative in parsed.negative {
            if record.normalizedName.contains(negative) || record.normalizedPath.contains(negative) {
                return nil
            }
        }

        var total = 0
        for part in parsed.positive {
            guard let partScore = score(part: part, record: record) else {
                return nil
            }
            total += partScore
        }

        let depthPenalty = min(record.path.filter { $0 == "/" }.count * 4, 120)
        let hiddenPenalty = record.isHidden ? 35 : 0
        return total - depthPenalty - hiddenPenalty
    }

    public static func primaryHighlightToken(for query: String) -> String? {
        for part in parse(query).positive {
            switch part {
            case .fuzzy(let token), .exact(let token), .fileExtension(let token):
                return token
            }
        }
        return nil
    }

    private static func score(part: QueryPart, record: FileRecord) -> Int? {
        switch part {
        case .fileExtension(let ext):
            if record.fileExtension == ext {
                return 4_800
            }
            if record.fileExtension.hasPrefix(ext) {
                return 3_600
            }
            return nil
        case .exact(let token):
            if record.normalizedName.contains(token) {
                return 5_200
            }
            if record.normalizedPath.contains(token) {
                return 3_700
            }
            return nil
        case .fuzzy(let token):
            let nameScore = scoreString(record.normalizedName, token: token, basenameBias: true)
            let pathScore = scoreString(record.normalizedPath, token: token, basenameBias: false).map { $0 - 400 }
            let typoScore = typoScore(record: record, token: token)
            return [nameScore, pathScore, typoScore].compactMap { $0 }.max()
        }
    }

    private static func scoreString(_ text: String, token: String, basenameBias: Bool) -> Int? {
        guard !token.isEmpty, !text.isEmpty else { return nil }

        if text == token {
            return basenameBias ? 10_000 : 8_700
        }

        if text.hasPrefix(token) {
            return (basenameBias ? 9_200 : 8_000) - min(text.count, 300)
        }

        if let range = text.range(of: token) {
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            let boundaryBonus = isBoundary(in: text, at: range.lowerBound) ? 650 : 0
            return (basenameBias ? 7_700 : 6_900) + boundaryBonus - min(offset * 12, 900)
        }

        if let acronym = acronymScore(text: text, token: token) {
            return acronym
        }

        if let subsequence = subsequenceScore(text: text, token: token) {
            return subsequence
        }

        return nil
    }

    private static func typoScore(record: FileRecord, token: String) -> Int? {
        guard token.count >= 3 else { return nil }
        let maxDistance = token.count <= 5 ? 1 : 2
        var best: Int?

        for component in components(from: record.normalizedName) {
            guard abs(component.count - token.count) <= maxDistance else { continue }
            if let distance = boundedLevenshtein(component, token, limit: maxDistance) {
                let score = 4_500 - (distance * 500) - min(component.count, 100)
                best = max(best ?? Int.min, score)
            }
        }

        return best
    }

    private static func acronymScore(text: String, token: String) -> Int? {
        let acronym = String(text.enumerated().compactMap { index, char -> Character? in
            if index == 0 { return char }
            let stringIndex = text.index(text.startIndex, offsetBy: index)
            return isBoundary(in: text, at: stringIndex) ? char : nil
        })

        guard let score = subsequenceScore(text: acronym, token: token) else {
            return nil
        }

        return score + 1_000
    }

    private static func subsequenceScore(text: String, token: String) -> Int? {
        let textChars = Array(text)
        let tokenChars = Array(token)
        var tokenIndex = 0
        var firstMatch: Int?
        var lastMatch = 0
        var gapPenalty = 0
        var contiguousRuns = 0
        var currentRun = 0

        for (index, char) in textChars.enumerated() {
            guard tokenIndex < tokenChars.count else { break }
            if char == tokenChars[tokenIndex] {
                if firstMatch == nil {
                    firstMatch = index
                }
                if tokenIndex > 0 {
                    let gap = index - lastMatch - 1
                    gapPenalty += gap
                    currentRun = gap == 0 ? currentRun + 1 : 1
                } else {
                    currentRun = 1
                }
                contiguousRuns = max(contiguousRuns, currentRun)
                lastMatch = index
                tokenIndex += 1
            }
        }

        guard tokenIndex == tokenChars.count, let firstMatch else {
            return nil
        }

        let boundaryBonus = firstMatch == 0 ? 450 : 0
        let compactnessBonus = contiguousRuns * 70
        return 5_500 + boundaryBonus + compactnessBonus - min(gapPenalty * 18, 1_400) - min(firstMatch * 8, 700)
    }

    private static func components(from text: String) -> [String] {
        text.split { char in
            char == "/" || char == "-" || char == "_" || char == "." || char == " "
        }
        .map(String.init)
    }

    private static func isBoundary(in text: String, at index: String.Index) -> Bool {
        if index == text.startIndex {
            return true
        }
        let previous = text[text.index(before: index)]
        return previous == "/" || previous == "-" || previous == "_" || previous == "." || previous == " "
    }

    private static func splitQuery(_ query: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuote = false

        for char in query {
            if char == "\"" {
                current.append(char)
                inQuote.toggle()
            } else if char.isWhitespace && !inQuote {
                if !current.isEmpty {
                    parts.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }

        if !current.isEmpty {
            parts.append(current)
        }

        return parts
    }

    private static func boundedLevenshtein(_ lhs: String, _ rhs: String, limit: Int) -> Int? {
        let a = Array(lhs)
        let b = Array(rhs)
        guard abs(a.count - b.count) <= limit else { return nil }

        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            var rowMinimum = current[0]

            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
                rowMinimum = min(rowMinimum, current[j])
            }

            if rowMinimum > limit {
                return nil
            }

            swap(&previous, &current)
        }

        let distance = previous[b.count]
        return distance <= limit ? distance : nil
    }
}
