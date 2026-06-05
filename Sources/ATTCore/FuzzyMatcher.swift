import Foundation

protocol SearchRecordReadable {
    var path: String { get }
    var name: String { get }
    var directoryPath: String { get }
    var fileExtension: String { get }
    var sizeBytes: UInt64 { get }
    var modifiedTime: TimeInterval { get }
    var createdTime: TimeInterval? { get }
    var isDirectory: Bool { get }
    var isHidden: Bool { get }
    var volumeName: String { get }
    var normalizedName: String { get }
    var normalizedPath: String { get }
    var rootPath: String? { get }
}

extension SearchRecordReadable {
    var rootPath: String? { nil }
}

extension FileRecord: SearchRecordReadable {}
extension RecordSearchView: SearchRecordReadable {}

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
        return explain(record: record, parsedQuery: parsedQuery)?.score
    }

    static func score(record: RecordSearchView, parsedQuery: ParsedQuery) -> Int? {
        guard !parsedQuery.isEmpty else { return 0 }
        return explain(record: record, parsedQuery: parsedQuery)?.score
    }

    public static func explain(record: FileRecord, query: String) -> MatchExplanation? {
        explain(record: record, parsedQuery: parse(query))
    }

    public static func explain(record: FileRecord, parsedQuery: ParsedQuery) -> MatchExplanation? {
        explainReadable(record: record, parsedQuery: parsedQuery)
    }

    static func explain(record: RecordSearchView, parsedQuery: ParsedQuery) -> MatchExplanation? {
        explainReadable(record: record, parsedQuery: parsedQuery)
    }

    private static func explainReadable<Record: SearchRecordReadable>(record: Record, parsedQuery: ParsedQuery) -> MatchExplanation? {
        guard !parsedQuery.isEmpty else { return nil }

        for negative in parsedQuery.negative {
            if explain(clause: negative, record: record) != nil {
                return nil
            }
        }

        var total = 0
        var spans: [MatchSpan] = []
        var best: MatchExplanation?
        for clause in parsedQuery.positive {
            guard let explanation = explain(clause: clause, record: record) else {
                return nil
            }
            total += explanation.score
            spans.append(contentsOf: explanation.spans)
            if bestMatch(explanation, beats: best) {
                best = explanation
            }
        }

        let depthPenalty = min(record.path.filter { $0 == "/" }.count * 4, 120)
        let hiddenPenalty = record.isHidden ? 35 : 0
        let finalScore = total - depthPenalty - hiddenPenalty
        guard let best else { return nil }
        let reason = parsedQuery.positive.count == 1
            ? best.reason
            : "Matched all query terms"
        return MatchExplanation(
            matchClass: best.matchClass,
            score: finalScore,
            field: best.field,
            reason: reason,
            spans: spans
        )
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

    private static func score<Record: SearchRecordReadable>(clause: QueryClause, record: Record) -> Int? {
        explain(clause: clause, record: record)?.score
    }

    private static func score<Record: SearchRecordReadable>(part: QueryPart, record: Record) -> Int? {
        explain(part: part, record: record)?.score
    }

    private static func explain<Record: SearchRecordReadable>(clause: QueryClause, record: Record) -> MatchExplanation? {
        clause.alternatives
            .compactMap { explain(part: $0, record: record) }
            .max { lhs, rhs in
                if lhs.quality != rhs.quality {
                    return lhs.quality < rhs.quality
                }
                return lhs.score < rhs.score
            }
    }

    private static func explain<Record: SearchRecordReadable>(part: QueryPart, record: Record) -> MatchExplanation? {
        switch part {
        case .fileExtension(let pattern, let mode):
            return extensionExplanation(record.fileExtension, pattern: pattern, mode: mode)
        case .kind(let token):
            return kindExplanation(record: record, token: token)
        case .text(let field, let pattern, let mode):
            return textExplanation(record: record, field: field, pattern: pattern, mode: mode)
        }
    }

    private static func textScore<Record: SearchRecordReadable>(record: Record, field: QueryField, pattern: SearchPattern, mode: MatchMode) -> Int? {
        textExplanation(record: record, field: field, pattern: pattern, mode: mode)?.score
    }

    private static func textExplanation<Record: SearchRecordReadable>(
        record: Record,
        field: QueryField,
        pattern: SearchPattern,
        mode: MatchMode
    ) -> MatchExplanation? {
        let token = pattern.token
        guard !token.isEmpty else { return nil }

        switch mode {
        case .exact:
            return exactExplanation(record: record, field: field, token: token)
        case .wildcard:
            return wildcardExplanation(record: record, field: field, pattern: token)
        case .fuzzy:
            if tokenContainsPathSeparator(token) {
                return structuredPathExplanation(record: record, field: field, token: token)
            }

            switch field {
            case .any:
                let nameMatch = stringExplanation(
                    text: record.normalizedName,
                    sourceText: record.name,
                    field: .name,
                    token: token,
                    basenameBias: true
                )
                let pathMatch = fuzzyPathExplanation(record: record, pattern: pattern).map {
                    adjustedExplanation($0, scoreDelta: -400, preferredClass: .weakPath)
                }
                return bestExplanation([nameMatch, pathMatch].compactMap { $0 })
            case .name:
                return stringExplanation(
                    text: record.normalizedName,
                    sourceText: record.name,
                    field: .name,
                    token: token,
                    basenameBias: true
                )
            case .path:
                return fuzzyPathExplanation(record: record, pattern: pattern)
            }
        }
    }

    private static func structuredPathScore<Record: SearchRecordReadable>(record: Record, field: QueryField, token: String) -> Int? {
        structuredPathExplanation(record: record, field: field, token: token)?.score
    }

    private static func structuredPathExplanation<Record: SearchRecordReadable>(
        record: Record,
        field: QueryField,
        token: String
    ) -> MatchExplanation? {
        switch field {
        case .name:
            return nil
        case .any, .path:
            guard let match = structuredPathMatches(path: record.normalizedPath, pattern: token) else {
                return nil
            }
            let base = field == .path ? 4_500 : 4_100
            let anchorBonus = match.startsAtRoot ? 450 : 0
            let consumedBonus = min(match.matchedSegments * 90, 720)
            let score = base + anchorBonus + consumedBonus - min(match.startSegment * 80, 800)
            return MatchExplanation(
                matchClass: .weakPath,
                score: score,
                field: .path,
                reason: "Path matched \"\(token)\""
            )
        }
    }

    private static func fuzzyPathScore<Record: SearchRecordReadable>(record: Record, pattern: SearchPattern) -> Int? {
        fuzzyPathExplanation(record: record, pattern: pattern)?.score
    }

    private static func fuzzyPathExplanation<Record: SearchRecordReadable>(
        record: Record,
        pattern: SearchPattern
    ) -> MatchExplanation? {
        if let exactPathMatch = exactExplanation(record: record, field: .path, token: pattern.token) {
            return adjustedExplanation(exactPathMatch, preferredClass: .weakPath, preferredField: .ancestorPath)
        }

        guard pattern.token.count <= 3 else {
            return nil
        }

        var best: MatchExplanation?
        for component in pathComponentsWithRanges(record.directoryPath, normalizedPath: FuzzyMatcher.normalize(record.directoryPath)) {
            if let match = stringExplanation(
                text: component.normalized,
                sourceText: component.source,
                field: .ancestorPath,
                token: pattern.token,
                basenameBias: false,
                baseUTF16Offset: component.utf16Offset
            ) {
                let adjusted = adjustedExplanation(match, preferredClass: .weakPath, preferredField: .ancestorPath)
                if bestMatch(adjusted, beats: best) {
                    best = adjusted
                }
            }
        }
        return best
    }

    private static func extensionScore(_ extensionValue: String, pattern: SearchPattern, mode: MatchMode) -> Int? {
        extensionExplanation(extensionValue, pattern: pattern, mode: mode)?.score
    }

    static func extensionExplanation(_ extensionValue: String, pattern: SearchPattern, mode: MatchMode) -> MatchExplanation? {
        let token = pattern.token
        guard !token.isEmpty else { return nil }

        switch mode {
        case .exact:
            guard extensionValue == token else { return nil }
            return MatchExplanation(
                matchClass: .exact,
                score: 4_900,
                field: .fileExtension,
                reason: "Extension exactly matched \"\(token)\"",
                spans: [MatchSpan(field: .fileExtension, location: 0, length: extensionValue.utf16.count, style: .contiguous)]
            )
        case .wildcard:
            guard wildcardMatches(extensionValue, pattern: token) else { return nil }
            return MatchExplanation(
                matchClass: .substring,
                score: 4_700,
                field: .fileExtension,
                reason: "Extension matched wildcard \"\(token)\""
            )
        case .fuzzy:
            if extensionValue == token {
                return MatchExplanation(
                    matchClass: .exact,
                    score: 4_800,
                    field: .fileExtension,
                    reason: "Extension exactly matched \"\(token)\"",
                    spans: [MatchSpan(field: .fileExtension, location: 0, length: extensionValue.utf16.count, style: .contiguous)]
                )
            }
            if extensionValue.hasPrefix(token) {
                return MatchExplanation(
                    matchClass: .prefix,
                    score: 3_600,
                    field: .fileExtension,
                    reason: "Extension starts with \"\(token)\"",
                    spans: [MatchSpan(field: .fileExtension, location: 0, length: token.utf16.count, style: .contiguous)]
                )
            }
            return nil
        }
    }

    private static func kindScore<Record: SearchRecordReadable>(record: Record, token: String) -> Int? {
        kindExplanation(record: record, token: token)?.score
    }

    private static func kindExplanation<Record: SearchRecordReadable>(record: Record, token: String) -> MatchExplanation? {
        let values = record.isDirectory ? ["folder", "directory", "dir"] : ["file"]
        guard values.contains(where: { $0.hasPrefix(token) }) else { return nil }
        return MatchExplanation(
            matchClass: .metadata,
            score: 4_400,
            field: .kind,
            reason: "Kind matched \"\(token)\""
        )
    }

    private static func exactScore<Record: SearchRecordReadable>(record: Record, field: QueryField, token: String) -> Int? {
        exactExplanation(record: record, field: field, token: token)?.score
    }

    private static func exactExplanation<Record: SearchRecordReadable>(
        record: Record,
        field: QueryField,
        token: String
    ) -> MatchExplanation? {
        func scoreCandidate(_ text: String, base: Int) -> Int? {
            guard let range = text.range(of: token) else { return nil }
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            let boundaryBonus = isBoundary(in: text, at: range.lowerBound) ? 500 : 0
            return base + boundaryBonus - min(offset * 10, 900)
        }

        func explanation(
            normalizedText: String,
            sourceText: String,
            field: MatchField,
            base: Int,
            baseUTF16Offset: Int = 0
        ) -> MatchExplanation? {
            guard let range = normalizedText.range(of: token) else { return nil }
            let start = normalizedText.distance(from: normalizedText.startIndex, to: range.lowerBound)
            let end = normalizedText.distance(from: normalizedText.startIndex, to: range.upperBound)
            let score = scoreCandidate(normalizedText, base: base) ?? base
            let matchClass: MatchClass = normalizedText == token ? .exact : (start == 0 ? .prefix : .substring)
            return MatchExplanation(
                matchClass: matchClass,
                score: score,
                field: field,
                reason: reason(for: field, token: token, kind: matchClass),
                spans: [span(field: field, sourceText: sourceText, start: start, end: end, style: .contiguous, baseUTF16Offset: baseUTF16Offset)]
            )
        }

        switch field {
        case .any:
            let nameMatch = explanation(normalizedText: record.normalizedName, sourceText: record.name, field: .name, base: 5_200)
            let pathMatch = explanation(normalizedText: FuzzyMatcher.normalize(record.directoryPath), sourceText: record.directoryPath, field: .path, base: 3_700)
            return bestExplanation([nameMatch, pathMatch].compactMap { $0 })
        case .name:
            return explanation(normalizedText: record.normalizedName, sourceText: record.name, field: .name, base: 5_200)
        case .path:
            return explanation(normalizedText: FuzzyMatcher.normalize(record.directoryPath), sourceText: record.directoryPath, field: .path, base: 4_000)
        }
    }

    private static func wildcardScore<Record: SearchRecordReadable>(record: Record, field: QueryField, pattern: String) -> Int? {
        wildcardExplanation(record: record, field: field, pattern: pattern)?.score
    }

    private static func wildcardExplanation<Record: SearchRecordReadable>(
        record: Record,
        field: QueryField,
        pattern: String
    ) -> MatchExplanation? {
        func scoreCandidate(_ text: String, base: Int) -> Int? {
            wildcardMatches(text, pattern: pattern) ? base - min(text.count, 300) : nil
        }

        func explanation(text: String, field: MatchField, base: Int) -> MatchExplanation? {
            guard let score = scoreCandidate(text, base: base) else { return nil }
            return MatchExplanation(
                matchClass: .substring,
                score: score,
                field: field,
                reason: reason(for: field, token: pattern, kind: .substring)
            )
        }

        switch field {
        case .any:
            let nameMatch = tokenContainsPathSeparator(pattern) ? nil : explanation(text: record.normalizedName, field: .name, base: 5_100)
            let pathMatch = pathWildcardExplanation(record.normalizedPath, pattern: pattern, base: 3_900)
            return bestExplanation([nameMatch, pathMatch].compactMap { $0 })
        case .name:
            guard !tokenContainsPathSeparator(pattern) else { return nil }
            return explanation(text: record.normalizedName, field: .name, base: 5_100)
        case .path:
            return pathWildcardExplanation(record.normalizedPath, pattern: pattern, base: 4_100)
        }
    }

    private static func pathWildcardScore(_ path: String, pattern: String, base: Int) -> Int? {
        pathWildcardExplanation(path, pattern: pattern, base: base)?.score
    }

    private static func pathWildcardExplanation(_ path: String, pattern: String, base: Int) -> MatchExplanation? {
        if tokenContainsPathSeparator(pattern) || pattern.contains("**") {
            guard let match = structuredPathMatches(path: path, pattern: pattern) else {
                return nil
            }
            let anchorBonus = match.startsAtRoot ? 450 : 0
            let consumedBonus = min(match.matchedSegments * 80, 640)
            let score = base + anchorBonus + consumedBonus - min(match.startSegment * 70, 700)
            return MatchExplanation(
                matchClass: .weakPath,
                score: score,
                field: .path,
                reason: "Path matched \"\(pattern)\""
            )
        }

        guard wildcardMatches(path, pattern: pattern) else { return nil }
        return MatchExplanation(
            matchClass: .weakPath,
            score: base - min(path.count, 300),
            field: .path,
            reason: "Path matched wildcard \"\(pattern)\""
        )
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
        case .any where parsed.pattern.token.hasPrefix("*.") && parsed.pattern.token.count > 2:
            return .fileExtension(makeSearchPattern(normalizedExtensionToken(parsed.pattern.token), mode: parsed.mode), mode: parsed.mode)
        case .any where parsed.pattern.token.hasPrefix(".") && parsed.pattern.token.count > 1:
            let extensionToken = String(parsed.pattern.token.dropFirst())
            return .fileExtension(makeSearchPattern(extensionToken, mode: .exact), mode: .exact)
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
            let extensionToken = normalizedExtensionToken(parsed.pattern.token)
            guard !extensionToken.isEmpty else { return nil }
            let mode: MatchMode = parsed.mode == .fuzzy ? .exact : parsed.mode
            return .fileExtension(makeSearchPattern(extensionToken, mode: mode), mode: mode)
        case .kind:
            return .kind(parsed.pattern.token)
        }
    }

    private static func normalizedExtensionToken(_ token: String) -> String {
        if token.hasPrefix("*.") {
            return String(token.dropFirst(2))
        }
        if token.hasPrefix(".") {
            return String(token.dropFirst())
        }
        return token
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
        } else if containsWildcardSyntax(value) {
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

    private static func bestExplanation(_ matches: [MatchExplanation]) -> MatchExplanation? {
        matches.max { lhs, rhs in
            if lhs.quality != rhs.quality {
                return lhs.quality < rhs.quality
            }
            return lhs.score < rhs.score
        }
    }

    private static func bestMatch(_ candidate: MatchExplanation, beats current: MatchExplanation?) -> Bool {
        guard let current else { return true }
        if candidate.quality != current.quality {
            return candidate.quality > current.quality
        }
        return candidate.score > current.score
    }

    private static func adjustedExplanation(
        _ explanation: MatchExplanation,
        scoreDelta: Int = 0,
        preferredClass: MatchClass? = nil,
        preferredField: MatchField? = nil
    ) -> MatchExplanation {
        let score = explanation.score + scoreDelta
        let field = preferredField ?? explanation.field
        let matchClass = preferredClass ?? explanation.matchClass
        let reason: String
        if matchClass == .weakPath && field == .ancestorPath {
            reason = "Path ancestor matched \"\(primaryToken(from: explanation.reason) ?? "query")\""
        } else if matchClass == .weakPath && field == .path {
            reason = "Path matched \"\(primaryToken(from: explanation.reason) ?? "query")\""
        } else {
            reason = explanation.reason
        }
        return MatchExplanation(
            matchClass: matchClass,
            score: score,
            field: field,
            reason: reason,
            spans: explanation.spans.map { span in
                MatchSpan(field: field, location: span.location, length: span.length, style: span.style)
            }
        )
    }

    private static func primaryToken(from reason: String) -> String? {
        guard let first = reason.firstIndex(of: "\"") else { return nil }
        let afterFirst = reason.index(after: first)
        guard let second = reason[afterFirst...].firstIndex(of: "\"") else { return nil }
        return String(reason[afterFirst..<second])
    }

    private static func scoreString(_ text: String, pattern: SearchPattern, basenameBias: Bool) -> Int? {
        stringExplanation(
            text: text,
            sourceText: text,
            field: basenameBias ? .name : .path,
            token: pattern.token,
            basenameBias: basenameBias
        )?.score
    }

    private static func stringExplanation(
        text: String,
        sourceText: String,
        field: MatchField,
        token: String,
        basenameBias: Bool,
        baseUTF16Offset: Int = 0
    ) -> MatchExplanation? {
        guard !token.isEmpty, !text.isEmpty else { return nil }

        if text == token {
            let score = basenameBias ? 10_000 : 8_700
            return MatchExplanation(
                matchClass: .exact,
                score: score,
                field: field,
                reason: reason(for: field, token: token, kind: .exact),
                spans: [span(field: field, sourceText: sourceText, start: 0, end: text.count, style: .contiguous, baseUTF16Offset: baseUTF16Offset)]
            )
        }

        if text.hasPrefix(token) {
            let score = (basenameBias ? 9_200 : 8_000) - min(text.count, 300)
            return MatchExplanation(
                matchClass: .prefix,
                score: score,
                field: field,
                reason: reason(for: field, token: token, kind: .prefix),
                spans: [span(field: field, sourceText: sourceText, start: 0, end: token.count, style: .contiguous, baseUTF16Offset: baseUTF16Offset)]
            )
        }

        if let range = text.range(of: token) {
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            let boundaryBonus = isBoundary(in: text, at: range.lowerBound) ? 650 : 0
            let score = (basenameBias ? 7_700 : 6_900) + boundaryBonus - min(offset * 12, 900)
            let end = text.distance(from: text.startIndex, to: range.upperBound)
            return MatchExplanation(
                matchClass: .substring,
                score: score,
                field: field,
                reason: reason(for: field, token: token, kind: .substring),
                spans: [span(field: field, sourceText: sourceText, start: offset, end: end, style: .contiguous, baseUTF16Offset: baseUTF16Offset)]
            )
        }

        if let acronym = acronymExplanation(
            text: text,
            sourceText: sourceText,
            field: field,
            token: token,
            baseUTF16Offset: baseUTF16Offset
        ) {
            return acronym
        }

        if token.count <= 3 {
            if let short = shortTokenSubsequenceExplanation(
                text: text,
                sourceText: sourceText,
                field: field,
                token: token,
                baseUTF16Offset: baseUTF16Offset
            ) {
                return short
            }
        }

        return typoExplanation(
            text: text,
            sourceText: sourceText,
            field: field,
            token: token,
            baseUTF16Offset: baseUTF16Offset
        )
    }

    private static func acronymExplanation(
        text: String,
        sourceText: String,
        field: MatchField,
        token: String,
        baseUTF16Offset: Int
    ) -> MatchExplanation? {
        let textChars = Array(text)
        let tokenChars = Array(token)
        let boundaryOffsets = textChars.indices.filter {
            isBoundary(in: text, sourceText: sourceText, atCharacterOffset: $0)
        }
        guard !boundaryOffsets.isEmpty else { return nil }

        var tokenIndex = 0
        var positions: [Int] = []
        for offset in boundaryOffsets {
            guard tokenIndex < tokenChars.count else { break }
            if textChars[offset] == tokenChars[tokenIndex] {
                positions.append(offset)
                tokenIndex += 1
            }
        }

        guard tokenIndex == tokenChars.count, let first = positions.first, let last = positions.last else {
            return nil
        }

        let score = 6_400 - min(first * 8, 600) - min((last - first) * 4, 700)
        return MatchExplanation(
            matchClass: .near,
            score: score,
            field: field,
            reason: reason(for: field, token: token, kind: .near),
            spans: positions.map {
                span(field: field, sourceText: sourceText, start: $0, end: $0 + 1, style: .subsequence, baseUTF16Offset: baseUTF16Offset)
            }
        )
    }

    private static func shortTokenSubsequenceExplanation(
        text: String,
        sourceText: String,
        field: MatchField,
        token: String,
        baseUTF16Offset: Int
    ) -> MatchExplanation? {
        let textChars = Array(text)
        let tokenChars = Array(token)
        var tokenIndex = 0
        var positions: [Int] = []
        var lastMatch = 0
        var gapPenalty = 0
        var contiguousRuns = 0
        var currentRun = 0

        for (index, char) in textChars.enumerated() {
            guard tokenIndex < tokenChars.count else { break }
            if char == tokenChars[tokenIndex] {
                positions.append(index)
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

        guard tokenIndex == tokenChars.count, let first = positions.first, let last = positions.last else {
            return nil
        }

        let spanWidth = last - first + 1
        let startsAtBoundary = isBoundary(in: text, sourceText: sourceText, atCharacterOffset: first)
        let endsAtBoundary = isBoundary(in: text, sourceText: sourceText, atCharacterOffset: last)
        guard spanWidth <= token.count + 1 || startsAtBoundary || endsAtBoundary else {
            return nil
        }

        let boundaryBonus = startsAtBoundary ? 450 : 0
        let compactnessBonus = contiguousRuns * 70
        let score = 5_500 + boundaryBonus + compactnessBonus - min(gapPenalty * 24, 1_600) - min(first * 8, 700)
        return MatchExplanation(
            matchClass: .near,
            score: score,
            field: field,
            reason: reason(for: field, token: token, kind: .near),
            spans: positions.map {
                span(field: field, sourceText: sourceText, start: $0, end: $0 + 1, style: .subsequence, baseUTF16Offset: baseUTF16Offset)
            }
        )
    }

    private static func typoExplanation(
        text: String,
        sourceText: String,
        field: MatchField,
        token: String,
        baseUTF16Offset: Int
    ) -> MatchExplanation? {
        guard token.count >= 3 else { return nil }
        let maxDistance = token.count <= 5 ? 1 : 2
        var best: MatchExplanation?

        for component in componentsWithRanges(sourceText, normalizedText: text) {
            if token.count <= 3, component.normalized.count >= token.count {
                let componentChars = Array(component.normalized)
                for start in 0...(componentChars.count - token.count) {
                    let end = start + token.count
                    let window = String(componentChars[start..<end])
                    guard boundedDamerauLevenshtein(window, token, limit: 1) != nil else { continue }
                    guard isBoundary(in: component.normalized, sourceText: component.source, atCharacterOffset: start) else {
                        continue
                    }
                    let score = 4_300 - min(start * 12, 500)
                    let candidate = MatchExplanation(
                        matchClass: .near,
                        score: score,
                        field: field,
                        reason: reason(for: field, token: token, kind: .near),
                        spans: [
                            span(
                                field: field,
                                sourceText: component.source,
                                start: start,
                                end: end,
                                style: .typo,
                                baseUTF16Offset: baseUTF16Offset + component.utf16Offset
                            )
                        ]
                    )
                    if bestMatch(candidate, beats: best) {
                        best = candidate
                    }
                }
            }

            guard abs(component.normalized.count - token.count) <= maxDistance else { continue }
            guard let distance = boundedDamerauLevenshtein(component.normalized, token, limit: maxDistance) else { continue }
            let score = 4_500 - (distance * 500) - min(component.normalized.count, 100)
            let candidate = MatchExplanation(
                matchClass: .near,
                score: score,
                field: field,
                reason: reason(for: field, token: token, kind: .near),
                spans: [
                    MatchSpan(
                        field: field,
                        location: baseUTF16Offset + component.utf16Offset,
                        length: component.source.utf16.count,
                        style: .typo
                    )
                ]
            )
            if bestMatch(candidate, beats: best) {
                best = candidate
            }
        }

        return best
    }

    private static func typoScore<Record: SearchRecordReadable>(record: Record, token: String) -> Int? {
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

    private struct ComponentWithRange {
        let source: String
        let normalized: String
        let utf16Offset: Int
    }

    private static func componentsWithRanges(_ sourceText: String, normalizedText: String) -> [ComponentWithRange] {
        splitComponentsWithRanges(sourceText, normalizedText: normalizedText, separators: isComponentSeparator)
    }

    private static func pathComponentsWithRanges(_ sourcePath: String, normalizedPath: String) -> [ComponentWithRange] {
        splitComponentsWithRanges(sourcePath, normalizedText: normalizedPath, separators: isComponentSeparator)
    }

    private static func splitComponentsWithRanges(
        _ sourceText: String,
        normalizedText: String,
        separators: (Character) -> Bool
    ) -> [ComponentWithRange] {
        let sourceChars = Array(sourceText)
        guard !sourceChars.isEmpty else { return [] }

        var components: [ComponentWithRange] = []
        var componentStart: Int?

        func appendComponent(end: Int) {
            guard let start = componentStart, start < end else { return }
            let sourceStart = sourceText.index(sourceText.startIndex, offsetBy: min(start, sourceText.count))
            let sourceEnd = sourceText.index(sourceText.startIndex, offsetBy: min(end, sourceText.count))
            let source = String(sourceText[sourceStart..<sourceEnd])
            let normalized = FuzzyMatcher.normalize(source)
            components.append(ComponentWithRange(
                source: source,
                normalized: normalized,
                utf16Offset: utf16Offset(in: sourceText, characterOffset: start)
            ))
        }

        for (offset, char) in sourceChars.enumerated() {
            if separators(char) {
                appendComponent(end: offset)
                componentStart = nil
            } else if componentStart == nil {
                componentStart = offset
            }
        }
        appendComponent(end: sourceChars.count)

        if components.isEmpty, !normalizedText.isEmpty {
            components.append(ComponentWithRange(source: sourceText, normalized: normalizedText, utf16Offset: 0))
        }

        return components
    }

    private static func span(
        field: MatchField,
        sourceText: String,
        start: Int,
        end: Int,
        style: MatchSpanStyle,
        baseUTF16Offset: Int = 0
    ) -> MatchSpan {
        let lower = max(0, min(start, sourceText.count))
        let upper = max(lower, min(end, sourceText.count))
        let location = baseUTF16Offset + utf16Offset(in: sourceText, characterOffset: lower)
        let length = utf16Offset(in: sourceText, characterOffset: upper) - utf16Offset(in: sourceText, characterOffset: lower)
        return MatchSpan(field: field, location: location, length: length, style: style)
    }

    private static func utf16Offset(in text: String, characterOffset: Int) -> Int {
        let clamped = max(0, min(characterOffset, text.count))
        let index = text.index(text.startIndex, offsetBy: clamped)
        return text.utf16.distance(from: text.utf16.startIndex, to: index.samePosition(in: text.utf16) ?? text.utf16.endIndex)
    }

    private static func reason(for field: MatchField, token: String, kind: MatchClass) -> String {
        let quoted = "\"\(token)\""
        switch (field, kind) {
        case (.name, .exact):
            return "Name exactly matched \(quoted)"
        case (.name, .prefix):
            return "Name starts with \(quoted)"
        case (.name, .substring):
            return "Name contains \(quoted)"
        case (.name, .near):
            return "Name nearly matched \(quoted)"
        case (.path, .weakPath), (.ancestorPath, .weakPath):
            return "Path ancestor matched \(quoted)"
        case (.path, _), (.ancestorPath, _):
            return "Path matched \(quoted)"
        case (.fileExtension, .exact):
            return "Extension exactly matched \(quoted)"
        case (.fileExtension, .prefix):
            return "Extension starts with \(quoted)"
        case (.kind, _):
            return "Kind matched \(quoted)"
        default:
            return "Matched \(quoted)"
        }
    }

    private static func components(from text: String) -> [String] {
        text.split { char in
            isComponentSeparator(char)
        }
        .map(String.init)
    }

    private static func isComponentSeparator(_ char: Character) -> Bool {
        char == "/" || char == "\\" || char == "-" || char == "_" || char == "." || char == " "
    }

    private static func isBoundary(in text: String, at index: String.Index) -> Bool {
        if index == text.startIndex {
            return true
        }
        let previous = text[text.index(before: index)]
        return isComponentSeparator(previous)
    }

    private static func isBoundary(in text: String, atCharacterOffset offset: Int) -> Bool {
        guard offset > 0 else { return true }
        guard offset < text.count else { return false }

        let index = text.index(text.startIndex, offsetBy: offset)
        return isBoundary(in: text, at: index)
    }

    private static func isBoundary(in text: String, sourceText: String, atCharacterOffset offset: Int) -> Bool {
        guard offset > 0 else { return true }
        if offset < text.count, isBoundary(in: text, atCharacterOffset: offset) {
            return true
        }

        let sourceChars = Array(sourceText)
        guard offset > 0, offset < sourceChars.count else { return false }
        let previous = sourceChars[offset - 1]
        let current = sourceChars[offset]
        if isComponentSeparator(previous) {
            return true
        }
        let previousScalar = String(previous).unicodeScalars.first
        let currentScalar = String(current).unicodeScalars.first
        let nextScalar = offset + 1 < sourceChars.count ? String(sourceChars[offset + 1]).unicodeScalars.first : nil
        let previousIsLowerOrDigit = previousScalar.map {
            CharacterSet.lowercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0)
        } ?? false
        let previousIsUpper = previousScalar.map { CharacterSet.uppercaseLetters.contains($0) } ?? false
        let currentIsUpper = currentScalar.map { CharacterSet.uppercaseLetters.contains($0) } ?? false
        let nextIsLower = nextScalar.map { CharacterSet.lowercaseLetters.contains($0) } ?? false
        return (previousIsLowerOrDigit && currentIsUpper) || (previousIsUpper && currentIsUpper && nextIsLower)
    }

    private enum WildcardToken {
        case star
        case single
        case literal(Character)
        case characterClass(Set<Character>, inverted: Bool)

        func matches(_ character: Character) -> Bool {
            switch self {
            case .star:
                return true
            case .single:
                return true
            case .literal(let expected):
                return character == expected
            case .characterClass(let members, let inverted):
                let contains = members.contains(character)
                return inverted ? !contains : contains
            }
        }
    }

    private static func containsWildcardSyntax(_ value: String) -> Bool {
        value.contains("*") || value.contains("?") || wildcardTokens(from: value).contains {
            if case .characterClass = $0 {
                return true
            }
            return false
        }
    }

    static func exactWildcardLiteralAlternatives(_ pattern: String, maxAlternatives: Int = 128) -> [String]? {
        var alternatives = [""]

        for token in wildcardTokens(from: pattern) {
            switch token {
            case .star, .single:
                return nil
            case .literal(let character):
                for index in alternatives.indices {
                    alternatives[index].append(character)
                }
            case .characterClass(let members, let inverted):
                guard !inverted else { return nil }
                let sortedMembers = members.sorted { String($0) < String($1) }
                guard !sortedMembers.isEmpty, alternatives.count * sortedMembers.count <= maxAlternatives else {
                    return nil
                }

                var expanded: [String] = []
                expanded.reserveCapacity(alternatives.count * sortedMembers.count)
                for alternative in alternatives {
                    for member in sortedMembers {
                        expanded.append(alternative + String(member))
                    }
                }
                alternatives = expanded
            }
        }

        var seen = Set<String>()
        return alternatives.filter { seen.insert($0).inserted }
    }

    static func wildcardMatches(_ text: String, pattern: String) -> Bool {
        let textChars = Array(text)
        let patternTokens = wildcardTokens(from: pattern)
        guard !patternTokens.isEmpty else { return false }

        var previous = Array(repeating: false, count: textChars.count + 1)
        previous[0] = true

        for patternToken in patternTokens {
            var current = Array(repeating: false, count: textChars.count + 1)

            if case .star = patternToken {
                current[0] = previous[0]
                if !textChars.isEmpty {
                    for index in 1...textChars.count {
                        current[index] = previous[index] || current[index - 1]
                    }
                }
            } else {
                if !textChars.isEmpty {
                    for index in 1...textChars.count {
                        current[index] = previous[index - 1] && patternToken.matches(textChars[index - 1])
                    }
                }
            }

            previous = current
        }

        return previous[textChars.count]
    }

    private static func wildcardTokens(from pattern: String) -> [WildcardToken] {
        let characters = Array(pattern)
        var tokens: [WildcardToken] = []
        var index = 0

        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                tokens.append(.star)
                index += 1
            case "?":
                tokens.append(.single)
                index += 1
            case "[":
                if let parsed = wildcardCharacterClass(in: characters, startIndex: index) {
                    tokens.append(parsed.token)
                    index = parsed.nextIndex
                } else {
                    tokens.append(.literal(character))
                    index += 1
                }
            default:
                tokens.append(.literal(character))
                index += 1
            }
        }

        return tokens
    }

    private static func wildcardCharacterClass(
        in characters: [Character],
        startIndex: Int
    ) -> (token: WildcardToken, nextIndex: Int)? {
        var index = startIndex + 1
        guard index < characters.count else { return nil }

        var inverted = false
        if characters[index] == "!" || characters[index] == "^" {
            inverted = true
            index += 1
        }

        var members = Set<Character>()
        var previous: Character?
        var hasMember = false

        while index < characters.count {
            let character = characters[index]
            if character == "]", hasMember {
                return (.characterClass(members, inverted: inverted), index + 1)
            }

            if
                character == "-",
                let previousMember = previous,
                index + 1 < characters.count,
                characters[index + 1] != "]",
                addWildcardRange(from: previousMember, through: characters[index + 1], into: &members)
            {
                previous = characters[index + 1]
                hasMember = true
                index += 2
                continue
            }

            members.insert(character)
            previous = character
            hasMember = true
            index += 1
        }

        return nil
    }

    private static func addWildcardRange(from start: Character, through end: Character, into members: inout Set<Character>) -> Bool {
        let startScalars = Array(start.unicodeScalars)
        let endScalars = Array(end.unicodeScalars)
        guard startScalars.count == 1, endScalars.count == 1 else {
            return false
        }

        let startScalar = startScalars[0]
        let endScalar = endScalars[0]
        guard startScalar.value <= endScalar.value else {
            return false
        }

        for value in startScalar.value...endScalar.value {
            guard let scalar = UnicodeScalar(value) else { return false }
            members.insert(Character(scalar))
        }
        return true
    }

    private struct StructuredPathMatch {
        let startSegment: Int
        let matchedSegments: Int
        let startsAtRoot: Bool
    }

    private static func structuredPathMatches(path: String, pattern rawPattern: String) -> StructuredPathMatch? {
        let pattern = rawPattern.replacingOccurrences(of: "\\", with: "/")
        let path = path.replacingOccurrences(of: "\\", with: "/")
        let isRootAnchored = pattern.hasPrefix("/")
        let pathSegments = splitPathSegments(from: path)
        let patternSegments = splitPathSegments(from: pattern)

        guard !patternSegments.isEmpty, !pathSegments.isEmpty else {
            return nil
        }

        if isRootAnchored {
            return structuredPathMatches(
                pathSegments: pathSegments,
                patternSegments: patternSegments,
                startSegment: 0,
                startsAtRoot: path.hasPrefix("/")
            )
        }

        for start in pathSegments.indices {
            if let match = structuredPathMatches(
                pathSegments: pathSegments,
                patternSegments: patternSegments,
                startSegment: start,
                startsAtRoot: false
            ) {
                return match
            }
        }

        return nil
    }

    private static func structuredPathMatches(
        pathSegments: [String],
        patternSegments: [String],
        startSegment: Int,
        startsAtRoot: Bool
    ) -> StructuredPathMatch? {
        var memo: Set<Int> = []

        func memoKey(patternIndex: Int, pathIndex: Int) -> Int {
            (patternIndex << 16) | pathIndex
        }

        func match(patternIndex: Int, pathIndex: Int) -> Int? {
            if patternIndex == patternSegments.count {
                return pathIndex
            }

            let key = memoKey(patternIndex: patternIndex, pathIndex: pathIndex)
            if memo.contains(key) {
                return nil
            }

            let patternSegment = patternSegments[patternIndex]
            if patternSegment == "**" {
                if patternIndex == patternSegments.count - 1 {
                    return pathSegments.count
                }

                for nextPathIndex in pathIndex...pathSegments.count {
                    if let end = match(patternIndex: patternIndex + 1, pathIndex: nextPathIndex) {
                        return end
                    }
                }

                memo.insert(key)
                return nil
            }

            guard pathIndex < pathSegments.count else {
                memo.insert(key)
                return nil
            }

            guard structuredSegmentMatches(pathSegments[pathIndex], pattern: patternSegment) else {
                memo.insert(key)
                return nil
            }

            if let end = match(patternIndex: patternIndex + 1, pathIndex: pathIndex + 1) {
                return end
            }

            memo.insert(key)
            return nil
        }

        guard let endSegment = match(patternIndex: 0, pathIndex: startSegment) else {
            return nil
        }

        return StructuredPathMatch(
            startSegment: startSegment,
            matchedSegments: max(endSegment - startSegment, 0),
            startsAtRoot: startsAtRoot
        )
    }

    private static func structuredSegmentMatches(_ segment: String, pattern: String) -> Bool {
        if containsWildcardSyntax(pattern) {
            return wildcardMatches(segment, pattern: pattern)
        }
        return segment.hasPrefix(pattern)
    }

    private static func splitPathSegments(from value: String) -> [String] {
        value.split { $0 == "/" || $0 == "\\" }.map(String.init)
    }

    private static func tokenContainsPathSeparator(_ token: String) -> Bool {
        token.contains("/") || token.contains("\\")
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

    private static func boundedDamerauLevenshtein(_ lhs: String, _ rhs: String, limit: Int) -> Int? {
        let a = Array(lhs)
        let b = Array(rhs)
        guard abs(a.count - b.count) <= limit else { return nil }
        guard !a.isEmpty else { return b.count <= limit ? b.count : nil }
        guard !b.isEmpty else { return a.count <= limit ? a.count : nil }

        var matrix = Array(
            repeating: Array(repeating: 0, count: b.count + 1),
            count: a.count + 1
        )
        for i in 0...a.count {
            matrix[i][0] = i
        }
        for j in 0...b.count {
            matrix[0][j] = j
        }

        for i in 1...a.count {
            var rowMinimum = matrix[i][0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(
                    matrix[i - 1][j] + 1,
                    matrix[i][j - 1] + 1,
                    matrix[i - 1][j - 1] + cost
                )
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, matrix[i - 2][j - 2] + 1)
                }
                matrix[i][j] = value
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > limit {
                return nil
            }
        }

        let distance = matrix[a.count][b.count]
        return distance <= limit ? distance : nil
    }
}

private extension String {
    var removingWildcardSyntax: String {
        filter { $0 != "*" && $0 != "?" && $0 != "[" && $0 != "]" && $0 != "!" && $0 != "^" }
    }
}
