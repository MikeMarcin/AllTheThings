import Foundation

public enum FuzzyMatcher {
    public struct ParsedQuery: Sendable {
        let positive: [QueryClause]
        let negative: [QueryClause]

        var isEmpty: Bool {
            positive.isEmpty && negative.isEmpty
        }
    }

    struct QueryClause: Sendable {
        let alternatives: [QueryPart]
    }

    struct SearchPattern: Sendable {
        let token: String
    }

    enum QueryPart: Sendable {
        case text(field: QueryField, pattern: SearchPattern, mode: MatchMode)
        case fileExtension(SearchPattern, mode: MatchMode)
        case kind(String)
    }

    enum QueryField: Sendable {
        case any
        case name
        case path
    }

    enum MatchMode: Sendable {
        case fuzzy
        case exact
        case wildcard
    }

    public static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    public static func parse(_ query: String) -> ParsedQuery {
        let rawParts = splitQuery(query)
        var positives: [QueryClause] = []
        var negatives: [QueryClause] = []

        for raw in rawParts {
            let parsed = parseClause(raw)
            guard !parsed.clause.alternatives.isEmpty else {
                continue
            }

            if parsed.isNegative {
                negatives.append(parsed.clause)
            } else {
                positives.append(parsed.clause)
            }
        }

        return ParsedQuery(positive: positives, negative: negatives)
    }

    public static func score(record: FileRecord, query: String) -> Int? {
        let parsed = parse(query)
        return score(record: record, parsedQuery: parsed)
    }

    public static func score(record: FileRecord, parsedQuery: ParsedQuery) -> Int? {
        guard !parsedQuery.isEmpty else { return 0 }

        for negative in parsedQuery.negative {
            if score(clause: negative, record: record) != nil {
                return nil
            }
        }

        var total = 0
        for clause in parsedQuery.positive {
            guard let partScore = score(clause: clause, record: record) else {
                return nil
            }
            total += partScore
        }

        let depthPenalty = min(record.path.filter { $0 == "/" }.count * 4, 120)
        let hiddenPenalty = record.isHidden ? 35 : 0
        return total - depthPenalty - hiddenPenalty
    }

    public static func primaryHighlightToken(for query: String) -> String? {
        for clause in parse(query).positive {
            for part in clause.alternatives {
                switch part {
                case .text(_, let pattern, _):
                    return pattern.token.removingWildcardSyntax
                case .fileExtension(let pattern, _):
                    return pattern.token.removingWildcardSyntax
                case .kind:
                    continue
                }
            }
        }
        return nil
    }

    private static func score(clause: QueryClause, record: FileRecord) -> Int? {
        clause.alternatives.compactMap { score(part: $0, record: record) }.max()
    }

    private static func score(part: QueryPart, record: FileRecord) -> Int? {
        switch part {
        case .fileExtension(let pattern, let mode):
            return extensionScore(record.fileExtension, pattern: pattern, mode: mode)
        case .kind(let token):
            return kindScore(record: record, token: token)
        case .text(let field, let pattern, let mode):
            return textScore(record: record, field: field, pattern: pattern, mode: mode)
        }
    }

    private static func textScore(record: FileRecord, field: QueryField, pattern: SearchPattern, mode: MatchMode) -> Int? {
        let token = pattern.token
        guard !token.isEmpty else { return nil }

        switch mode {
        case .exact:
            return exactScore(record: record, field: field, token: token)
        case .wildcard:
            return wildcardScore(record: record, field: field, pattern: token)
        case .fuzzy:
            switch field {
            case .any:
                let nameScore = scoreString(record.normalizedName, pattern: pattern, basenameBias: true)
                let pathScore = fuzzyPathScore(record: record, pattern: pattern).map { $0 - 400 }
                let typoScore = typoScore(record: record, token: token)
                return [nameScore, pathScore, typoScore].compactMap { $0 }.max()
            case .name:
                let nameScore = scoreString(record.normalizedName, pattern: pattern, basenameBias: true)
                let typoScore = typoScore(record: record, token: token)
                return [nameScore, typoScore].compactMap { $0 }.max()
            case .path:
                return fuzzyPathScore(record: record, pattern: pattern)
            }
        }
    }

    private static func fuzzyPathScore(record: FileRecord, pattern: SearchPattern) -> Int? {
        if let exactPathScore = exactScore(record: record, field: .path, token: pattern.token) {
            return exactPathScore
        }

        guard pattern.token.count <= 3 else {
            return nil
        }

        var best: Int?
        for component in components(from: record.normalizedPath) {
            guard let score = scoreString(component, pattern: pattern, basenameBias: false) else {
                continue
            }
            best = max(best ?? Int.min, score)
        }
        return best
    }

    private static func extensionScore(_ extensionValue: String, pattern: SearchPattern, mode: MatchMode) -> Int? {
        let token = pattern.token
        guard !token.isEmpty else { return nil }

        switch mode {
        case .exact:
            return extensionValue == token ? 4_900 : nil
        case .wildcard:
            return wildcardMatches(extensionValue, pattern: token) ? 4_700 : nil
        case .fuzzy:
            if extensionValue == token {
                return 4_800
            }
            if extensionValue.hasPrefix(token) {
                return 3_600
            }
            return nil
        }
    }

    private static func kindScore(record: FileRecord, token: String) -> Int? {
        let values = record.isDirectory ? ["folder", "directory", "dir"] : ["file"]
        return values.contains { $0.hasPrefix(token) } ? 4_400 : nil
    }

    private static func exactScore(record: FileRecord, field: QueryField, token: String) -> Int? {
        func scoreCandidate(_ text: String, base: Int) -> Int? {
            guard let range = text.range(of: token) else { return nil }
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            let boundaryBonus = isBoundary(in: text, at: range.lowerBound) ? 500 : 0
            return base + boundaryBonus - min(offset * 10, 900)
        }

        switch field {
        case .any:
            let nameScore = scoreCandidate(record.normalizedName, base: 5_200)
            let pathScore = scoreCandidate(record.normalizedPath, base: 3_700)
            return [nameScore, pathScore].compactMap { $0 }.max()
        case .name:
            return scoreCandidate(record.normalizedName, base: 5_200)
        case .path:
            return scoreCandidate(record.normalizedPath, base: 4_000)
        }
    }

    private static func wildcardScore(record: FileRecord, field: QueryField, pattern: String) -> Int? {
        func scoreCandidate(_ text: String, base: Int) -> Int? {
            wildcardMatches(text, pattern: pattern) ? base - min(text.count, 300) : nil
        }

        switch field {
        case .any:
            let nameScore = scoreCandidate(record.normalizedName, base: 5_100)
            let pathScore = scoreCandidate(record.normalizedPath, base: 3_900)
            return [nameScore, pathScore].compactMap { $0 }.max()
        case .name:
            return scoreCandidate(record.normalizedName, base: 5_100)
        case .path:
            return scoreCandidate(record.normalizedPath, base: 4_100)
        }
    }

    private static func parseClause(_ raw: String) -> (isNegative: Bool, clause: QueryClause) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (false, QueryClause(alternatives: []))
        }

        let isNegative = (trimmed.hasPrefix("!") || trimmed.hasPrefix("-")) && trimmed.count > 1
        let body = isNegative ? String(trimmed.dropFirst()) : trimmed
        let alternatives = parseAlternatives(from: body)

        return (isNegative, QueryClause(alternatives: alternatives))
    }

    private static func parseAlternatives(from body: String) -> [QueryPart] {
        if let scoped = splitScopedTerm(body) {
            let values = splitFieldValues(scoped.value, field: scoped.field)
            return values.compactMap { parsePart(field: scoped.field, rawValue: $0) }
        }

        return splitAlternatives(body).compactMap { parsePart(field: .any, rawValue: $0) }
    }

    private static func parsePart(field: QueryField, rawValue: String) -> QueryPart? {
        let parsed = parsePattern(rawValue)
        guard !parsed.pattern.token.isEmpty else { return nil }

        switch field {
        case .any where parsed.pattern.token.hasPrefix(".") && parsed.pattern.token.count > 1:
            return .fileExtension(makeSearchPattern(String(parsed.pattern.token.dropFirst()), mode: parsed.mode), mode: parsed.mode)
        case .name, .path, .any:
            return .text(field: field, pattern: parsed.pattern, mode: parsed.mode)
        }
    }

    private static func parsePart(field: ScopedField, rawValue: String) -> QueryPart? {
        let parsed = parsePattern(rawValue)
        guard !parsed.pattern.token.isEmpty else { return nil }

        switch field {
        case .name:
            return .text(field: .name, pattern: parsed.pattern, mode: parsed.mode)
        case .path:
            return .text(field: .path, pattern: parsed.pattern, mode: parsed.mode)
        case .fileExtension:
            let extensionToken = parsed.pattern.token.hasPrefix(".") ? String(parsed.pattern.token.dropFirst()) : parsed.pattern.token
            guard !extensionToken.isEmpty else { return nil }
            return .fileExtension(makeSearchPattern(extensionToken, mode: parsed.mode), mode: parsed.mode)
        case .kind:
            return .kind(parsed.pattern.token)
        }
    }

    private enum ScopedField {
        case name
        case path
        case fileExtension
        case kind
    }

    private static func splitScopedTerm(_ body: String) -> (field: ScopedField, value: String)? {
        guard let colon = body.firstIndex(of: ":") else { return nil }

        let prefix = normalize(String(body[..<colon]))
        guard let field = scopedField(for: prefix) else { return nil }

        let valueStart = body.index(after: colon)
        return (field, String(body[valueStart...]))
    }

    private static func scopedField(for prefix: String) -> ScopedField? {
        switch prefix {
        case "name", "file", "filename", "basename":
            return .name
        case "path", "folder", "dir", "directory":
            return .path
        case "ext", "extension", "suffix":
            return .fileExtension
        case "kind", "type":
            return .kind
        default:
            return nil
        }
    }

    private static func splitFieldValues(_ value: String, field: ScopedField) -> [String] {
        switch field {
        case .fileExtension, .kind:
            return splitAlternatives(value).flatMap { splitCommaSeparated($0) }
        case .name, .path:
            return splitAlternatives(value)
        }
    }

    private static func parsePattern(_ rawValue: String) -> (pattern: SearchPattern, mode: MatchMode) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var mode: MatchMode = .fuzzy

        if value.hasPrefix("\"") {
            value.removeFirst()
            if value.hasSuffix("\"") {
                value.removeLast()
            }
            mode = .exact
        } else if value.hasSuffix("\"") {
            value.removeLast()
            mode = .exact
        } else if value.contains("*") || value.contains("?") {
            mode = .wildcard
        }

        let token = normalize(value)
        return (makeSearchPattern(token, mode: mode), mode)
    }

    private static func makeSearchPattern(_ token: String, mode: MatchMode) -> SearchPattern {
        SearchPattern(token: token)
    }

    private static func splitAlternatives(_ value: String) -> [String] {
        split(value, separators: ["|"])
    }

    private static func splitCommaSeparated(_ value: String) -> [String] {
        split(value, separators: [",", ";"])
    }

    private static func split(_ value: String, separators: Set<Character>) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuote = false

        for char in value {
            if char == "\"" {
                current.append(char)
                inQuote.toggle()
            } else if separators.contains(char) && !inQuote {
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

    private static func scoreString(_ text: String, pattern: SearchPattern, basenameBias: Bool) -> Int? {
        let token = pattern.token
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

        if token.count <= 3 {
            return subsequenceScore(text: text, token: token)
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

    private static func isBoundary(in text: String, atCharacterOffset offset: Int) -> Bool {
        guard offset > 0 else { return true }
        guard offset < text.count else { return false }

        let index = text.index(text.startIndex, offsetBy: offset)
        return isBoundary(in: text, at: index)
    }

    private static func wildcardMatches(_ text: String, pattern: String) -> Bool {
        let textChars = Array(text)
        let patternChars = Array(pattern)
        guard !patternChars.isEmpty else { return false }

        var previous = Array(repeating: false, count: textChars.count + 1)
        previous[0] = true

        for patternChar in patternChars {
            var current = Array(repeating: false, count: textChars.count + 1)

            if patternChar == "*" {
                current[0] = previous[0]
                if !textChars.isEmpty {
                    for index in 1...textChars.count {
                        current[index] = previous[index] || current[index - 1]
                    }
                }
            } else {
                if !textChars.isEmpty {
                    for index in 1...textChars.count {
                        current[index] = previous[index - 1] && (patternChar == "?" || patternChar == textChars[index - 1])
                    }
                }
            }

            previous = current
        }

        return previous[textChars.count]
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

private extension String {
    var removingWildcardSyntax: String {
        filter { $0 != "*" && $0 != "?" }
    }
}
