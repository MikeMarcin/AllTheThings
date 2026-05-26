import Foundation

public enum SortColumn: String, Codable, CaseIterable, Sendable {
    case relevance
    case name
    case path
    case modified
    case created
    case size
    case fileExtension
    case kind
    case volume
}

public struct SortSpec: Codable, Equatable, Sendable {
    public let column: SortColumn
    public let ascending: Bool

    public init(column: SortColumn, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }
}

public struct SearchRequest: Sendable {
    public let query: String
    public let sort: SortSpec

    public init(query: String, sort: SortSpec) {
        self.query = query
        self.sort = sort
    }
}

public struct SearchResult: Identifiable, Sendable {
    public let record: FileRecord
    public let score: Int

    public var id: UInt64 {
        record.id
    }
}

public struct SearchResponse: Sendable {
    public let results: [SearchResult]
    public let totalMatches: Int
    public let elapsed: TimeInterval

    public init(results: [SearchResult], totalMatches: Int, elapsed: TimeInterval) {
        self.results = results
        self.totalMatches = totalMatches
        self.elapsed = elapsed
    }
}

public struct IndexStats: Sendable {
    public let indexedCount: Int
    public let isIndexing: Bool
    public let status: String
    public let lastUpdated: Date

    public init(indexedCount: Int, isIndexing: Bool, status: String, lastUpdated: Date) {
        self.indexedCount = indexedCount
        self.isIndexing = isIndexing
        self.status = status
        self.lastUpdated = lastUpdated
    }
}

public final class FileIndex: @unchecked Sendable {
    public var onStatsChanged: (@MainActor @Sendable (IndexStats) -> Void)? {
        get {
            lock.withLock {
                statsChangedHandler
            }
        }
        set {
            lock.withLock {
                statsChangedHandler = newValue
            }
        }
    }

    private struct PersistedSnapshot: Codable {
        let savedAt: Date
        let records: [FileRecord]
    }

    private struct ExactTextFastQuery {
        let clauses: [ExactTextFastClause]
    }

    private struct ExactTextFastClause {
        let alternatives: [ExactTextFastAlternative]
    }

    private struct ExactTextFastAlternative {
        let field: FuzzyMatcher.QueryField
        let token: String
        let tokenBytes: [UInt8]
    }

    private struct UTF8Match {
        let offset: Int
        let isBoundary: Bool
        let textByteCount: Int
    }

    private struct CandidateBitSet {
        private var words: [UInt64]

        init(count: Int) {
            words = Array(repeating: 0, count: (count + 63) / 64)
        }

        mutating func insert(_ index: Int) {
            words[index >> 6] |= UInt64(1) << UInt64(index & 63)
        }

        func contains(_ index: Int) -> Bool {
            (words[index >> 6] & (UInt64(1) << UInt64(index & 63))) != 0
        }
    }

    private final class SearchSnapshot: @unchecked Sendable {
        static let empty = SearchSnapshot(records: [], buildsSearchStructures: false)

        let records: [FileRecord]
        let modifiedDescending: [Int]
        let modifiedAscending: [Int]
        let gramIndex: [Int: [Int32]]
        let hasSortedOrder: Bool

        init(records: [FileRecord], buildsSearchStructures: Bool = true) {
            self.records = records
            self.hasSortedOrder = buildsSearchStructures

            if buildsSearchStructures {
                self.gramIndex = Self.makeGramIndex(records: records)
                let sortedByModified = records.indices.sorted { lhs, rhs in
                    let left = records[lhs]
                    let right = records[rhs]
                    if left.modifiedTime != right.modifiedTime {
                        return left.modifiedTime > right.modifiedTime
                    }
                    if left.normalizedName != right.normalizedName {
                        return left.normalizedName < right.normalizedName
                    }
                    return left.path < right.path
                }
                self.modifiedDescending = sortedByModified
                self.modifiedAscending = Array(sortedByModified.reversed())
            } else {
                self.gramIndex = [:]
                self.modifiedDescending = []
                self.modifiedAscending = []
            }
        }

        func orderedIndices(for sort: SortSpec, queryIsEmpty: Bool) -> [Int]? {
            guard hasSortedOrder else { return nil }

            switch sort.column {
            case .modified:
                return sort.ascending ? modifiedAscending : modifiedDescending
            case .relevance where queryIsEmpty:
                return modifiedDescending
            case .relevance, .name, .path, .created, .size, .fileExtension, .kind, .volume:
                return nil
            }
        }

        func candidateIndices(containing tokenBytes: [UInt8]) -> [Int32]? {
            guard !gramIndex.isEmpty else { return nil }

            let keys = FileIndex.searchGramKeys(for: tokenBytes)
            guard !keys.isEmpty else { return nil }

            var postings: [[Int32]] = []
            postings.reserveCapacity(keys.count)

            for key in keys {
                guard let values = gramIndex[key] else {
                    return []
                }
                postings.append(values)
            }

            postings.sort { $0.count < $1.count }
            if postings.count == 1 {
                return postings[0]
            }

            return FileIndex.intersectPostingLists(postings)
        }

        private static func makeGramIndex(records: [FileRecord]) -> [Int: [Int32]] {
            var index: [Int: [Int32]] = [:]
            var keys = Set<Int>()

            for (recordIndex, record) in records.enumerated() {
                keys.removeAll(keepingCapacity: true)
                FileIndex.collectSearchGramKeys(from: record.normalizedName, into: &keys)
                FileIndex.collectSearchGramKeys(from: record.normalizedPath, into: &keys)

                let storedIndex = Int32(recordIndex)
                for key in keys {
                    index[key, default: []].append(storedIndex)
                }
            }

            return index
        }
    }

    private let lock = NSLock()
    private let fileManager: FileManager
    private let snapshotURL: URL
    private let persistenceQueue = DispatchQueue(label: "att.index.persistence", qos: .utility)
    private var recordsByPath: [String: FileRecord] = [:]
    private var searchSnapshot = SearchSnapshot.empty
    private var searchSnapshotRevision: UInt64 = 0
    private var roots: [String] = []
    private var generation: UInt64 = 0
    private var persistRevision: UInt64 = 0
    private var indexing = false
    private var status = "Starting"
    private var lastUpdated = Date()
    private var statsChangedHandler: (@MainActor @Sendable (IndexStats) -> Void)?

    public init(fileManager: FileManager = .default, applicationName: String = "AllTheThings") {
        self.fileManager = fileManager

        let supportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let supportDirectory = supportRoot.appendingPathComponent(applicationName, isDirectory: true)
        try? fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        self.snapshotURL = supportDirectory.appendingPathComponent("filename-index.json", isDirectory: false)

        loadSnapshot()
    }

    public func currentStats() -> IndexStats {
        lockedStats()
    }

    public func allRoots() -> [URL] {
        lock.withLock {
            roots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
    }

    public func replaceRootsAndRebuild(_ rootURLs: [URL]) {
        let canonicalRoots = canonicalizedRoots(rootURLs)
        let currentGeneration = lock.withLock { () -> UInt64 in
            generation &+= 1
            roots = canonicalRoots.map(\.path)
            indexing = true
            status = "Indexing \(canonicalRoots.count) scope\(canonicalRoots.count == 1 ? "" : "s")"
            lastUpdated = Date()
            return generation
        }

        publishStats()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.rebuild(roots: canonicalRoots, generation: currentGeneration)
        }
    }

    public func refresh(paths rawPaths: [String]) {
        let paths = Array(Set(rawPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })).prefix(128)
        guard !paths.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.refreshNow(paths: Array(paths))
        }
    }

    public func search(_ request: SearchRequest, maxResults: Int = 20_000) -> SearchResponse {
        search(request, maxResults: maxResults, shouldCancel: { false }) ?? SearchResponse(results: [], totalMatches: 0, elapsed: 0)
    }

    public func search(
        _ request: SearchRequest,
        maxResults: Int = 20_000,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        let started = Date()
        let snapshot = lock.withLock { searchSnapshot }
        let records = snapshot.records

        guard !shouldCancel() else { return nil }

        let trimmedQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedQuery = FuzzyMatcher.parse(trimmedQuery)
        let exactTextFastQuery = Self.exactTextFastQuery(from: parsedQuery)
        let boundedMaxResults = max(maxResults, 0)
        var matches: [SearchResult] = []
        matches.reserveCapacity(min(records.count, boundedMaxResults))
        let trimThreshold = boundedMaxResults > 0 ? boundedMaxResults * 5 : 0
        var total = 0

        func trimMatches() {
            guard boundedMaxResults > 0, matches.count > boundedMaxResults else { return }
            matches.sort {
                Self.compare($0, $1, sort: request.sort, queryIsEmpty: parsedQuery.isEmpty)
            }
            matches.removeSubrange(boundedMaxResults..<matches.count)
        }

        func appendMatch(_ match: SearchResult) {
            total += 1
            guard boundedMaxResults > 0 else { return }
            matches.append(match)
            if matches.count > trimThreshold {
                trimMatches()
            }
        }

        if parsedQuery.isEmpty {
            let orderedRecords = snapshot.orderedIndices(for: request.sort, queryIsEmpty: true)
            for (offset, index) in (orderedRecords ?? Array(records.indices)).enumerated() {
                if offset.isMultiple(of: 512), shouldCancel() {
                    return nil
                }
                let record = records[index]
                appendMatch(SearchResult(record: record, score: 0))
            }
        } else {
            if let exactTextFastQuery {
                if let indexedResponse = Self.indexedExactTextSearch(
                    snapshot: snapshot,
                    request: request,
                    query: exactTextFastQuery,
                    maxResults: boundedMaxResults,
                    started: started,
                    shouldCancel: shouldCancel
                ) {
                    return indexedResponse
                }

                if let orderedIndices = snapshot.orderedIndices(for: request.sort, queryIsEmpty: false) {
                    for (offset, index) in orderedIndices.enumerated() {
                        if offset.isMultiple(of: 512), shouldCancel() {
                            return nil
                        }
                        let record = records[index]
                        guard let score = Self.exactTextScore(record: record, query: exactTextFastQuery) else {
                            continue
                        }
                        total += 1
                        if matches.count < boundedMaxResults {
                            matches.append(SearchResult(record: record, score: score))
                        }
                    }

                    if total > 0 {
                        guard !shouldCancel() else { return nil }
                        return SearchResponse(results: matches, totalMatches: total, elapsed: Date().timeIntervalSince(started))
                    }
                } else {
                    for (offset, record) in records.enumerated() {
                        if offset.isMultiple(of: 512), shouldCancel() {
                            return nil
                        }
                        if let score = Self.exactTextScore(record: record, query: exactTextFastQuery) {
                            appendMatch(SearchResult(record: record, score: score))
                        }
                    }

                    if total > 0 {
                        guard !shouldCancel() else { return nil }
                        trimMatches()

                        guard !shouldCancel() else { return nil }
                        return SearchResponse(results: matches, totalMatches: total, elapsed: Date().timeIntervalSince(started))
                    }
                }
            }

            for (offset, record) in records.enumerated() {
                if offset.isMultiple(of: 512), shouldCancel() {
                    return nil
                }
                if let score = FuzzyMatcher.score(record: record, parsedQuery: parsedQuery) {
                    appendMatch(SearchResult(record: record, score: score))
                }
            }
        }

        guard !shouldCancel() else { return nil }

        trimMatches()

        guard !shouldCancel() else { return nil }

        return SearchResponse(results: matches, totalMatches: total, elapsed: Date().timeIntervalSince(started))
    }

    private static func indexedExactTextSearch(
        snapshot: SearchSnapshot,
        request: SearchRequest,
        query: ExactTextFastQuery,
        maxResults: Int,
        started: Date,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        guard
            let orderedIndices = snapshot.orderedIndices(for: request.sort, queryIsEmpty: false),
            query.clauses.count == 1,
            let clause = query.clauses.first,
            clause.alternatives.count == 1,
            let alternative = clause.alternatives.first,
            let candidateIndices = snapshot.candidateIndices(containing: alternative.tokenBytes),
            !candidateIndices.isEmpty
        else {
            return nil
        }

        var matches = CandidateBitSet(count: snapshot.records.count)
        var total = 0
        let candidateListIsExact = alternative.field == .any && alternative.tokenBytes.count <= 3

        for (offset, candidate) in candidateIndices.enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }

            let index = Int(candidate)
            guard index >= 0, index < snapshot.records.count else {
                continue
            }

            if !candidateListIsExact {
                guard exactTextScore(
                    record: snapshot.records[index],
                    field: alternative.field,
                    token: alternative.token,
                    tokenBytes: alternative.tokenBytes
                ) != nil else {
                    continue
                }
            }

            total += 1
            matches.insert(index)
        }

        guard total > 0, !shouldCancel() else {
            return nil
        }

        var results: [SearchResult] = []
        results.reserveCapacity(min(maxResults, total))

        if maxResults > 0 {
            for (offset, index) in orderedIndices.enumerated() {
                if offset.isMultiple(of: 512), shouldCancel() {
                    return nil
                }
                guard matches.contains(index) else {
                    continue
                }
                results.append(SearchResult(record: snapshot.records[index], score: 0))
                if results.count >= maxResults {
                    break
                }
            }
        }

        guard !shouldCancel() else { return nil }
        return SearchResponse(results: results, totalMatches: total, elapsed: Date().timeIntervalSince(started))
    }

    private static func exactTextFastQuery(from parsedQuery: FuzzyMatcher.ParsedQuery) -> ExactTextFastQuery? {
        guard parsedQuery.negative.isEmpty, !parsedQuery.positive.isEmpty else {
            return nil
        }

        var clauses: [ExactTextFastClause] = []
        clauses.reserveCapacity(parsedQuery.positive.count)

        for clause in parsedQuery.positive {
            var alternatives: [ExactTextFastAlternative] = []
            alternatives.reserveCapacity(clause.alternatives.count)

            for alternative in clause.alternatives {
                switch alternative {
                case .text(let field, let pattern, .fuzzy):
                    guard !pattern.token.isEmpty else { return nil }
                    alternatives.append(ExactTextFastAlternative(
                        field: field,
                        token: pattern.token,
                        tokenBytes: Array(pattern.token.utf8)
                    ))
                case .text, .fileExtension, .kind:
                    return nil
                }
            }

            guard !alternatives.isEmpty else {
                return nil
            }
            clauses.append(ExactTextFastClause(alternatives: alternatives))
        }

        return ExactTextFastQuery(clauses: clauses)
    }

    private static func exactTextScore(record: FileRecord, query: ExactTextFastQuery) -> Int? {
        var total = 0

        for clause in query.clauses {
            var best: Int?

            for alternative in clause.alternatives {
                guard let score = exactTextScore(
                    record: record,
                    field: alternative.field,
                    token: alternative.token,
                    tokenBytes: alternative.tokenBytes
                ) else {
                    continue
                }
                best = max(best ?? Int.min, score)
            }

            guard let best else {
                return nil
            }
            total += best
        }

        let depthPenalty = pathDepthPenalty(record.normalizedPath)
        let hiddenPenalty = record.isHidden ? 35 : 0
        return total - depthPenalty - hiddenPenalty
    }

    private static func exactTextScore(record: FileRecord, field: FuzzyMatcher.QueryField, token: String, tokenBytes: [UInt8]) -> Int? {
        switch field {
        case .any:
            let nameScore = exactNameScore(record.normalizedName, tokenBytes: tokenBytes)
            let pathScore = exactPathScore(record.normalizedPath, tokenBytes: tokenBytes, base: 3_600)
            switch (nameScore, pathScore) {
            case (.some(let name), .some(let path)):
                return max(name, path)
            case (.some(let name), .none):
                return name
            case (.none, .some(let path)):
                return path
            case (.none, .none):
                return nil
            }
        case .name:
            return exactNameScore(record.normalizedName, tokenBytes: tokenBytes)
        case .path:
            return exactPathScore(record.normalizedPath, tokenBytes: tokenBytes, base: 4_000)
        }
    }

    private static func exactNameScore(_ text: String, tokenBytes: [UInt8]) -> Int? {
        guard let match = firstUTF8Match(in: text, token: tokenBytes) else {
            return nil
        }

        if match.offset == 0, match.textByteCount == tokenBytes.count {
            return 10_000
        }

        if match.offset == 0 {
            return 9_200 - min(match.textByteCount, 300)
        }

        let boundaryBonus = match.isBoundary ? 650 : 0
        return 7_700 + boundaryBonus - min(match.offset * 12, 900)
    }

    private static func exactPathScore(_ text: String, tokenBytes: [UInt8], base: Int) -> Int? {
        guard let match = firstUTF8Match(in: text, token: tokenBytes) else {
            return nil
        }

        let boundaryBonus = match.isBoundary ? 500 : 0
        return base + boundaryBonus - min(match.offset * 10, 900)
    }

    private static func collectSearchGramKeys(from text: String, into keys: inout Set<Int>) {
        guard !text.isEmpty else { return }
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return }

        let maximumLength = min(3, bytes.count)
        for length in 1...maximumLength {
            let lastStart = bytes.count - length
            for start in 0...lastStart {
                keys.insert(searchGramKey(bytes: bytes, start: start, length: length))
            }
        }
    }

    private static func searchGramKeys(for tokenBytes: [UInt8]) -> [Int] {
        guard !tokenBytes.isEmpty else { return [] }

        if tokenBytes.count <= 3 {
            return [searchGramKey(bytes: tokenBytes, start: 0, length: tokenBytes.count)]
        }

        var keys = Set<Int>()
        let lastStart = tokenBytes.count - 3
        for start in 0...lastStart {
            keys.insert(searchGramKey(bytes: tokenBytes, start: start, length: 3))
        }
        return Array(keys)
    }

    private static func searchGramKey(bytes: [UInt8], start: Int, length: Int) -> Int {
        var key = length << 24
        for offset in 0..<length {
            key |= Int(bytes[start + offset]) << ((2 - offset) * 8)
        }
        return key
    }

    private static func intersectPostingLists(_ postings: [[Int32]]) -> [Int32] {
        guard var result = postings.first else {
            return []
        }

        for posting in postings.dropFirst() {
            if result.isEmpty {
                break
            }
            result = intersectPostingLists(result, posting)
        }

        return result
    }

    private static func intersectPostingLists(_ lhs: [Int32], _ rhs: [Int32]) -> [Int32] {
        var result: [Int32] = []
        result.reserveCapacity(min(lhs.count, rhs.count))

        var leftIndex = 0
        var rightIndex = 0

        while leftIndex < lhs.count, rightIndex < rhs.count {
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

    private static func firstUTF8Match(in text: String, token: [UInt8]) -> UTF8Match? {
        guard !token.isEmpty else { return nil }

        if let match = text.utf8.withContiguousStorageIfAvailable({ haystack -> UTF8Match? in
            firstUTF8Match(in: haystack, token: token)
        }) {
            return match
        }

        return firstUTF8Match(in: Array(text.utf8), token: token)
    }

    private static func firstUTF8Match(in haystack: UnsafeBufferPointer<UInt8>, token: [UInt8]) -> UTF8Match? {
        guard token.count <= haystack.count else { return nil }

        let first = token[0]
        let lastStart = haystack.count - token.count
        var index = 0

        while index <= lastStart {
            if haystack[index] == first {
                var tokenIndex = 1
                while tokenIndex < token.count, haystack[index + tokenIndex] == token[tokenIndex] {
                    tokenIndex += 1
                }

                if tokenIndex == token.count {
                    return UTF8Match(
                        offset: index,
                        isBoundary: index == 0 || isBoundaryByte(haystack[index - 1]),
                        textByteCount: haystack.count
                    )
                }
            }

            index += 1
        }

        return nil
    }

    private static func firstUTF8Match(in haystack: ArraySlice<UInt8>, token: [UInt8]) -> UTF8Match? {
        firstUTF8Match(in: Array(haystack), token: token)
    }

    private static func firstUTF8Match(in haystack: [UInt8], token: [UInt8]) -> UTF8Match? {
        guard token.count <= haystack.count else { return nil }

        let first = token[0]
        let lastStart = haystack.count - token.count
        var index = 0

        while index <= lastStart {
            if haystack[index] == first {
                var tokenIndex = 1
                while tokenIndex < token.count, haystack[index + tokenIndex] == token[tokenIndex] {
                    tokenIndex += 1
                }

                if tokenIndex == token.count {
                    return UTF8Match(
                        offset: index,
                        isBoundary: index == 0 || isBoundaryByte(haystack[index - 1]),
                        textByteCount: haystack.count
                    )
                }
            }

            index += 1
        }

        return nil
    }

    private static func pathDepthPenalty(_ path: String) -> Int {
        var slashCount = 0
        for byte in path.utf8 where byte == 47 {
            slashCount += 1
            if slashCount >= 30 {
                return 120
            }
        }
        return min(slashCount * 4, 120)
    }

    private static func isBoundaryByte(_ byte: UInt8) -> Bool {
        byte == 47 || byte == 45 || byte == 95 || byte == 46 || byte == 32
    }

    public func deleteSnapshot() {
        lock.withLock {
            recordsByPath.removeAll(keepingCapacity: true)
            searchSnapshot = .empty
            searchSnapshotRevision &+= 1
            status = "Index deleted"
            indexing = false
            lastUpdated = Date()
            persistRevision &+= 1
        }
        try? fileManager.removeItem(at: snapshotURL)
        publishStats()
    }

    private func loadSnapshot() {
        guard
            let data = try? Data(contentsOf: snapshotURL),
            let persisted = try? JSONDecoder().decode(PersistedSnapshot.self, from: data)
        else {
            lock.withLock {
                status = "No index yet"
                lastUpdated = Date()
            }
            return
        }

        let records = Dictionary(uniqueKeysWithValues: persisted.records.map { ($0.path, $0) })
        let snapshot = SearchSnapshot(records: Array(records.values))
        lock.withLock {
            recordsByPath = records
            searchSnapshot = snapshot
            searchSnapshotRevision &+= 1
            status = "Loaded \(records.count) indexed files"
            indexing = false
            lastUpdated = persisted.savedAt
        }
    }

    private func rebuild(roots rootURLs: [URL], generation currentGeneration: UInt64) {
        var localRecords: [String: FileRecord] = [:]
        let currentCount = lock.withLock { recordsByPath.count }
        localRecords.reserveCapacity(max(8_192, currentCount))

        var lastPublish = Date.distantPast
        var visited = 0

        func publishPartial(records: [String: FileRecord], visited: Int, force: Bool = false) {
            guard isCurrentGeneration(currentGeneration) else { return }
            let now = Date()
            guard force || now.timeIntervalSince(lastPublish) > 0.25 else { return }
            lastPublish = now
            replaceRecords(records, isIndexing: true, status: "Indexing \(visited.formatted()) files")
        }

        for root in rootURLs {
            guard isCurrentGeneration(currentGeneration) else { return }
            scan(root: root, into: &localRecords, visited: &visited) {
                publishPartial(records: $0, visited: $1)
            }
            publishPartial(records: localRecords, visited: visited, force: true)
        }

        guard isCurrentGeneration(currentGeneration) else { return }
        replaceRecords(localRecords, isIndexing: false, status: "Indexed \(localRecords.count.formatted()) files")
        schedulePersist()
    }

    private func scan(
        root: URL,
        into records: inout [String: FileRecord],
        visited: inout Int,
        progress: (_ records: [String: FileRecord], _ visited: Int) -> Void
    ) {
        guard fileManager.fileExists(atPath: root.path), !shouldExclude(root) else { return }

        if let rootRecord = FileRecord(url: root) {
            records[rootRecord.path] = rootRecord
            visited += 1
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(FileRecord.resourceKeys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return
        }

        for case let url as URL in enumerator {
            if shouldExclude(url) {
                enumerator.skipDescendants()
                continue
            }

            let values = try? url.resourceValues(forKeys: FileRecord.resourceKeys)
            if values?.isDirectory == true && isLikelyLoop(url) {
                enumerator.skipDescendants()
                continue
            }

            if let record = FileRecord(url: url, resourceValues: values) {
                records[record.path] = record
                visited += 1
            }

            if visited.isMultiple(of: 1_500) {
                progress(records, visited)
            }
        }
    }

    private func refreshNow(paths: [String]) {
        var upserts: [String: FileRecord] = [:]
        var deletedPrefixes: [String] = []
        var shallowDirectoryChildren: [String: Set<String>] = [:]

        for path in paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard !shouldExclude(url) else { continue }

            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                if let record = FileRecord(url: url) {
                    upserts[record.path] = record
                }

                if isDirectory.boolValue {
                    let children = scanDirectoryShallow(url)
                    shallowDirectoryChildren[url.path] = Set(children.map(\.path))
                    for record in children {
                        upserts[record.path] = record
                    }
                }
            } else {
                deletedPrefixes.append(url.path)
            }
        }

        guard !upserts.isEmpty || !deletedPrefixes.isEmpty || !shallowDirectoryChildren.isEmpty else {
            return
        }

        var snapshotRecords: [FileRecord] = []
        var snapshotRevision: UInt64 = 0

        lock.withLock {
            for prefix in deletedPrefixes {
                recordsByPath = recordsByPath.filter { path, _ in
                    path != prefix && !path.hasPrefix(prefix + "/")
                }
            }

            for (directory, currentChildren) in shallowDirectoryChildren {
                recordsByPath = recordsByPath.filter { _, record in
                    record.directoryPath != directory || currentChildren.contains(record.path)
                }
            }

            for (path, record) in upserts {
                recordsByPath[path] = record
            }

            searchSnapshotRevision &+= 1
            snapshotRevision = searchSnapshotRevision
            snapshotRecords = Array(recordsByPath.values)
            status = "Updated \(upserts.count + deletedPrefixes.count) changed path\(upserts.count + deletedPrefixes.count == 1 ? "" : "s")"
            lastUpdated = Date()
        }

        let snapshot = SearchSnapshot(records: snapshotRecords)
        lock.withLock {
            if searchSnapshotRevision == snapshotRevision {
                searchSnapshot = snapshot
            }
        }

        publishStats()
        schedulePersist()
    }

    private func scanDirectoryShallow(_ directory: URL) -> [FileRecord] {
        guard
            let children = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(FileRecord.resourceKeys),
                options: []
            )
        else {
            return []
        }

        return children.compactMap { child in
            guard !shouldExclude(child) else { return nil }
            let values = try? child.resourceValues(forKeys: FileRecord.resourceKeys)
            return FileRecord(url: child, resourceValues: values)
        }
    }

    private func replaceRecords(_ records: [String: FileRecord], isIndexing: Bool, status: String) {
        let snapshot = SearchSnapshot(records: Array(records.values), buildsSearchStructures: !isIndexing)
        lock.withLock {
            recordsByPath = records
            searchSnapshot = snapshot
            searchSnapshotRevision &+= 1
            indexing = isIndexing
            self.status = status
            lastUpdated = Date()
        }
        publishStats()
    }

    private func schedulePersist() {
        let revision = lock.withLock { () -> UInt64 in
            persistRevision &+= 1
            return persistRevision
        }

        persistenceQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.isPersistRevisionCurrent(revision) else { return }
            self.persistSnapshot()
        }
    }

    private func persistSnapshot() {
        let records = lock.withLock {
            Array(recordsByPath.values)
        }
        let snapshot = PersistedSnapshot(savedAt: Date(), records: records)

        do {
            let data = try JSONEncoder().encode(snapshot)
            let temporaryURL = snapshotURL.appendingPathExtension("tmp")
            try data.write(to: temporaryURL, options: .atomic)
            if fileManager.fileExists(atPath: snapshotURL.path) {
                try fileManager.removeItem(at: snapshotURL)
            }
            try fileManager.moveItem(at: temporaryURL, to: snapshotURL)
        } catch {
            lock.withLock {
                status = "Could not persist index: \(error.localizedDescription)"
                lastUpdated = Date()
            }
            publishStats()
        }
    }

    private func publishStats() {
        let update = lock.withLock {
            (
                stats: IndexStats(
                    indexedCount: recordsByPath.count,
                    isIndexing: indexing,
                    status: status,
                    lastUpdated: lastUpdated
                ),
                handler: statsChangedHandler
            )
        }

        guard let handler = update.handler else { return }
        let stats = update.stats
        Task { @MainActor in
            handler(stats)
        }
    }

    private func lockedStats() -> IndexStats {
        lock.withLock {
            IndexStats(
                indexedCount: recordsByPath.count,
                isIndexing: indexing,
                status: status,
                lastUpdated: lastUpdated
            )
        }
    }

    private func isCurrentGeneration(_ candidate: UInt64) -> Bool {
        lock.withLock {
            generation == candidate
        }
    }

    private func isPersistRevisionCurrent(_ candidate: UInt64) -> Bool {
        lock.withLock {
            persistRevision == candidate
        }
    }

    private func canonicalizedRoots(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            guard fileManager.fileExists(atPath: standardized.path), !seen.contains(standardized.path) else {
                return nil
            }
            seen.insert(standardized.path)
            return standardized
        }
    }

    private func shouldExclude(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let name = url.lastPathComponent

        if name == "node_modules" || name == "DerivedData" {
            return true
        }

        if path.hasSuffix("/.git/objects") || path.contains("/.git/objects/") {
            return true
        }

        if path.contains("/Library/Caches/") || path.hasSuffix("/Library/Caches") {
            return true
        }

        if path.contains("/.Trash/") || path.hasSuffix("/.Trash") {
            return true
        }

        return false
    }

    private func isLikelyLoop(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink == true
    }

    private static func compare(_ lhs: SearchResult, _ rhs: SearchResult, sort: SortSpec, queryIsEmpty: Bool) -> Bool {
        let ascending = sort.ascending

        func ordered<T: Comparable>(_ left: T, _ right: T) -> Bool? {
            guard left != right else { return nil }
            return ascending ? left < right : left > right
        }

        let primary: Bool?
        switch sort.column {
        case .relevance:
            if queryIsEmpty {
                primary = lhs.record.modifiedTime == rhs.record.modifiedTime ? nil : lhs.record.modifiedTime > rhs.record.modifiedTime
            } else if lhs.score != rhs.score {
                primary = lhs.score > rhs.score
            } else {
                primary = nil
            }
        case .name:
            primary = ordered(lhs.record.normalizedName, rhs.record.normalizedName)
        case .path:
            primary = ordered(lhs.record.normalizedPath, rhs.record.normalizedPath)
        case .modified:
            primary = ordered(lhs.record.modifiedTime, rhs.record.modifiedTime)
        case .created:
            primary = ordered(lhs.record.createdTime ?? 0, rhs.record.createdTime ?? 0)
        case .size:
            primary = ordered(lhs.record.sizeBytes, rhs.record.sizeBytes)
        case .fileExtension:
            primary = ordered(lhs.record.fileExtension, rhs.record.fileExtension)
        case .kind:
            primary = ordered(lhs.record.isDirectory ? "Folder" : "File", rhs.record.isDirectory ? "Folder" : "File")
        case .volume:
            primary = ordered(lhs.record.volumeName, rhs.record.volumeName)
        }

        if let primary {
            return primary
        }

        if lhs.record.normalizedName != rhs.record.normalizedName {
            return lhs.record.normalizedName < rhs.record.normalizedName
        }

        return lhs.record.path < rhs.record.path
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
