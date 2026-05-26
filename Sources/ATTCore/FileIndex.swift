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
    public let isLoadingSnapshot: Bool
    public let status: String
    public let lastUpdated: Date

    public init(
        indexedCount: Int,
        isIndexing: Bool,
        isLoadingSnapshot: Bool = false,
        status: String,
        lastUpdated: Date
    ) {
        self.indexedCount = indexedCount
        self.isIndexing = isIndexing
        self.isLoadingSnapshot = isLoadingSnapshot
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

    private enum SnapshotLoadState {
        case notStarted
        case loading
        case finished
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
        let nameGramIndex: [Int: [Int32]]
        let extensionIndex: [String: [Int32]]
        let hasSortedOrder: Bool

        init(records: [FileRecord], buildsSearchStructures: Bool = true) {
            self.records = records
            self.hasSortedOrder = buildsSearchStructures

            if buildsSearchStructures {
                self.gramIndex = Self.makeGramIndex(records: records)
                self.nameGramIndex = Self.makeNameGramIndex(records: records)
                self.extensionIndex = Self.makeExtensionIndex(records: records)
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
                self.nameGramIndex = [:]
                self.extensionIndex = [:]
                self.modifiedDescending = []
                self.modifiedAscending = []
            }
        }

        private init(
            records: [FileRecord],
            modifiedDescending: [Int],
            gramIndex: [Int: [Int32]],
            nameGramIndex: [Int: [Int32]],
            extensionIndex: [String: [Int32]]
        ) {
            self.records = records
            self.modifiedDescending = modifiedDescending
            self.modifiedAscending = Array(modifiedDescending.reversed())
            self.gramIndex = gramIndex
            self.nameGramIndex = nameGramIndex
            self.extensionIndex = extensionIndex
            self.hasSortedOrder = true
        }

        func updatingMetadata(for upserts: [String: FileRecord]) -> SearchSnapshot? {
            guard hasSortedOrder, !upserts.isEmpty else { return nil }

            let upsertPaths = Set(upserts.keys)
            var existingIndices: [String: Int] = [:]
            existingIndices.reserveCapacity(upserts.count)

            for (index, record) in records.enumerated() where upsertPaths.contains(record.path) {
                existingIndices[record.path] = index
                if existingIndices.count == upserts.count {
                    break
                }
            }

            guard existingIndices.count == upserts.count else {
                return nil
            }

            var updatedRecords = records
            var changedIndices: [Int] = []
            changedIndices.reserveCapacity(upserts.count)

            for (path, record) in upserts {
                guard let index = existingIndices[path] else {
                    return nil
                }
                updatedRecords[index] = record
                changedIndices.append(index)
            }

            let changed = Set(changedIndices)
            let unchangedDescending = modifiedDescending.filter { !changed.contains($0) }
            let changedDescending = changedIndices.sorted {
                Self.modifiedDescendingPrecedes($0, $1, records: updatedRecords)
            }
            let mergedDescending = Self.mergeModifiedDescending(
                changed: changedDescending,
                unchanged: unchangedDescending,
                records: updatedRecords
            )

            return SearchSnapshot(
                records: updatedRecords,
                modifiedDescending: mergedDescending,
                gramIndex: gramIndex,
                nameGramIndex: nameGramIndex,
                extensionIndex: extensionIndex
            )
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

        func candidateNameIndices(containing tokenBytes: [UInt8]) -> [Int32]? {
            guard !nameGramIndex.isEmpty else { return nil }

            let keys = FileIndex.searchGramKeys(for: tokenBytes)
            guard !keys.isEmpty else { return nil }

            var postings: [[Int32]] = []
            postings.reserveCapacity(keys.count)

            for key in keys {
                guard let values = nameGramIndex[key] else {
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

        func candidateNameIndices(containingAny tokenByteSets: [[UInt8]]) -> [Int32]? {
            guard !tokenByteSets.isEmpty else { return nil }

            var candidates: [Int32] = []
            for tokenBytes in tokenByteSets {
                guard let values = candidateNameIndices(containingAllBytes: tokenBytes) else {
                    return nil
                }
                candidates = FileIndex.unionPostingLists(candidates, values)
            }

            return candidates
        }

        private func candidateNameIndices(containingAllBytes tokenBytes: [UInt8]) -> [Int32]? {
            guard !nameGramIndex.isEmpty, !tokenBytes.isEmpty else { return nil }

            var postings: [[Int32]] = []
            postings.reserveCapacity(tokenBytes.count)

            for byte in tokenBytes {
                let key = FileIndex.searchGramKey(bytes: [byte], start: 0, length: 1)
                guard let values = nameGramIndex[key] else {
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

        func candidateIndices(fileExtension token: String, mode: FuzzyMatcher.MatchMode) -> [Int32]? {
            guard !extensionIndex.isEmpty, !token.isEmpty else { return nil }

            switch mode {
            case .exact:
                return extensionIndex[token] ?? []
            case .fuzzy:
                var candidates: [Int32] = []
                for (fileExtension, values) in extensionIndex where fileExtension == token || fileExtension.hasPrefix(token) {
                    candidates = FileIndex.unionPostingLists(candidates, values)
                }
                return candidates
            case .wildcard:
                if !token.contains("*"), !token.contains("?") {
                    return extensionIndex[token] ?? []
                }

                var candidates: [Int32] = []
                for (fileExtension, values) in extensionIndex where FileIndex.wildcardMatches(fileExtension, pattern: token) {
                    candidates = FileIndex.unionPostingLists(candidates, values)
                }
                return candidates
            }
        }

        private static func mergeModifiedDescending(changed: [Int], unchanged: [Int], records: [FileRecord]) -> [Int] {
            var merged: [Int] = []
            merged.reserveCapacity(changed.count + unchanged.count)

            var changedIndex = 0
            var unchangedIndex = 0

            while changedIndex < changed.count, unchangedIndex < unchanged.count {
                let changedRecordIndex = changed[changedIndex]
                let unchangedRecordIndex = unchanged[unchangedIndex]

                if modifiedDescendingPrecedes(changedRecordIndex, unchangedRecordIndex, records: records) {
                    merged.append(changedRecordIndex)
                    changedIndex += 1
                } else {
                    merged.append(unchangedRecordIndex)
                    unchangedIndex += 1
                }
            }

            if changedIndex < changed.count {
                merged.append(contentsOf: changed[changedIndex...])
            }

            if unchangedIndex < unchanged.count {
                merged.append(contentsOf: unchanged[unchangedIndex...])
            }

            return merged
        }

        private static func modifiedDescendingPrecedes(_ lhs: Int, _ rhs: Int, records: [FileRecord]) -> Bool {
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

        private static func makeNameGramIndex(records: [FileRecord]) -> [Int: [Int32]] {
            var index: [Int: [Int32]] = [:]
            var keys = Set<Int>()

            for (recordIndex, record) in records.enumerated() {
                keys.removeAll(keepingCapacity: true)
                FileIndex.collectSearchGramKeys(from: record.normalizedName, into: &keys)

                let storedIndex = Int32(recordIndex)
                for key in keys {
                    index[key, default: []].append(storedIndex)
                }
            }

            return index
        }

        private static func makeExtensionIndex(records: [FileRecord]) -> [String: [Int32]] {
            var index: [String: [Int32]] = [:]

            for (recordIndex, record) in records.enumerated() where !record.fileExtension.isEmpty {
                index[record.fileExtension, default: []].append(Int32(recordIndex))
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
    private var snapshotLoadState = SnapshotLoadState.notStarted
    private var indexing = false
    private var status = "Starting"
    private var lastUpdated = Date()
    private var statsChangedHandler: (@MainActor @Sendable (IndexStats) -> Void)?

    public init(
        fileManager: FileManager = .default,
        applicationName: String = "AllTheThings",
        loadsSnapshotImmediately: Bool = true
    ) {
        self.fileManager = fileManager

        let supportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let supportDirectory = supportRoot.appendingPathComponent(applicationName, isDirectory: true)
        try? fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        self.snapshotURL = supportDirectory.appendingPathComponent("filename-index.json", isDirectory: false)

        if loadsSnapshotImmediately {
            if beginSnapshotLoad() {
                loadSnapshotAfterBegin(generationAtStart: currentGeneration())
            }
        } else {
            lock.withLock {
                status = "Waiting to load index"
                lastUpdated = Date()
            }
        }
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
            snapshotLoadState = .finished
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

    @discardableResult
    public func loadSnapshotInBackground() -> Bool {
        guard beginSnapshotLoad() else { return false }
        let generationAtStart = currentGeneration()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.loadSnapshotAfterBegin(generationAtStart: generationAtStart)
        }

        return true
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

        func sortAndLimitMatches() {
            guard boundedMaxResults > 0 else { return }
            matches.sort {
                Self.compare($0, $1, sort: request.sort, queryIsEmpty: parsedQuery.isEmpty)
            }
            if matches.count > boundedMaxResults {
                matches.removeSubrange(boundedMaxResults..<matches.count)
            }
        }

        func trimMatches() {
            guard boundedMaxResults > 0, matches.count > boundedMaxResults else { return }
            sortAndLimitMatches()
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
                        sortAndLimitMatches()

                        guard !shouldCancel() else { return nil }
                        return SearchResponse(results: matches, totalMatches: total, elapsed: Date().timeIntervalSince(started))
                    }
                }
            }

            if let indexedResponse = Self.indexedCandidateSearch(
                snapshot: snapshot,
                request: request,
                parsedQuery: parsedQuery,
                maxResults: boundedMaxResults,
                started: started,
                shouldCancel: shouldCancel
            ) {
                return indexedResponse
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

        sortAndLimitMatches()

        guard !shouldCancel() else { return nil }

        return SearchResponse(results: matches, totalMatches: total, elapsed: Date().timeIntervalSince(started))
    }

    private static func indexedCandidateSearch(
        snapshot: SearchSnapshot,
        request: SearchRequest,
        parsedQuery: FuzzyMatcher.ParsedQuery,
        maxResults: Int,
        started: Date,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        guard let candidateIndices = candidateIndices(snapshot: snapshot, parsedQuery: parsedQuery) else {
            return nil
        }

        if candidateIndices.isEmpty {
            return SearchResponse(results: [], totalMatches: 0, elapsed: Date().timeIntervalSince(started))
        }

        guard candidateIndices.count < snapshot.records.count else {
            return nil
        }

        var matches: [SearchResult] = []
        matches.reserveCapacity(min(candidateIndices.count, maxResults))
        let trimThreshold = maxResults > 0 ? maxResults * 5 : 0
        var total = 0

        func sortAndLimitMatches() {
            guard maxResults > 0 else { return }
            matches.sort {
                compare($0, $1, sort: request.sort, queryIsEmpty: false)
            }
            if matches.count > maxResults {
                matches.removeSubrange(maxResults..<matches.count)
            }
        }

        func trimMatches() {
            guard maxResults > 0, matches.count > maxResults else { return }
            sortAndLimitMatches()
        }

        for (offset, candidate) in candidateIndices.enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }

            let index = Int(candidate)
            guard index >= 0, index < snapshot.records.count else {
                continue
            }

            let record = snapshot.records[index]
            guard let score = FuzzyMatcher.score(record: record, parsedQuery: parsedQuery) else {
                continue
            }

            total += 1
            guard maxResults > 0 else {
                continue
            }

            matches.append(SearchResult(record: record, score: score))
            if matches.count > trimThreshold {
                trimMatches()
            }
        }

        guard !shouldCancel() else { return nil }
        sortAndLimitMatches()

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

    private static func candidateIndices(snapshot: SearchSnapshot, parsedQuery: FuzzyMatcher.ParsedQuery) -> [Int32]? {
        var candidates: [Int32]?
        var foundUsableClause = false

        for clause in parsedQuery.positive {
            guard let clauseCandidates = candidateIndices(snapshot: snapshot, clause: clause) else {
                continue
            }

            foundUsableClause = true
            guard !clauseCandidates.isEmpty else {
                return []
            }

            if let current = candidates {
                candidates = intersectPostingLists(current, clauseCandidates)
            } else {
                candidates = clauseCandidates
            }

            if candidates?.isEmpty == true {
                return []
            }
        }

        return foundUsableClause ? candidates : nil
    }

    private static func candidateIndices(snapshot: SearchSnapshot, clause: FuzzyMatcher.QueryClause) -> [Int32]? {
        var candidates: [Int32] = []
        var foundUsableAlternative = false

        for alternative in clause.alternatives {
            guard let alternativeCandidates = candidateIndices(snapshot: snapshot, part: alternative) else {
                return nil
            }

            foundUsableAlternative = true
            candidates = unionPostingLists(candidates, alternativeCandidates)
        }

        return foundUsableAlternative ? candidates : nil
    }

    private static func candidateIndices(snapshot: SearchSnapshot, part: FuzzyMatcher.QueryPart) -> [Int32]? {
        switch part {
        case .kind:
            return nil
        case .fileExtension(let pattern, let mode):
            return snapshot.candidateIndices(fileExtension: pattern.token, mode: mode)
                ?? candidateIndices(snapshot: snapshot, token: pattern.token, mode: mode, allowsFuzzyPrefix: true)
        case .text(let field, let pattern, let mode):
            return candidateIndices(snapshot: snapshot, field: field, token: pattern.token, mode: mode)
        }
    }

    private static func candidateIndices(
        snapshot: SearchSnapshot,
        field: FuzzyMatcher.QueryField,
        token: String,
        mode: FuzzyMatcher.MatchMode
    ) -> [Int32]? {
        switch mode {
        case .exact:
            return snapshot.candidateIndices(containing: Array(token.utf8))
        case .wildcard:
            return candidateIndices(snapshot: snapshot, requiredFragments: wildcardRequiredFragments(from: token))
        case .fuzzy:
            if tokenContainsPathSeparator(token) {
                guard field != .name else {
                    return nil
                }
                return candidateIndices(snapshot: snapshot, requiredFragments: pathLiteralFragments(from: token))
            }

            return fuzzyTextCandidateIndices(snapshot: snapshot, field: field, token: token)
        }
    }

    private static func candidateIndices(
        snapshot: SearchSnapshot,
        token: String,
        mode: FuzzyMatcher.MatchMode,
        allowsFuzzyPrefix: Bool
    ) -> [Int32]? {
        switch mode {
        case .exact:
            return snapshot.candidateIndices(containing: Array(token.utf8))
        case .wildcard:
            return candidateIndices(snapshot: snapshot, requiredFragments: wildcardRequiredFragments(from: token))
        case .fuzzy:
            guard allowsFuzzyPrefix else {
                return nil
            }
            return snapshot.candidateIndices(containing: Array(token.utf8))
        }
    }

    private static func candidateIndices(snapshot: SearchSnapshot, requiredFragments fragments: [[UInt8]]) -> [Int32]? {
        guard !fragments.isEmpty else {
            return nil
        }

        var candidates: [Int32]?

        for fragment in fragments {
            guard let fragmentCandidates = snapshot.candidateIndices(containing: fragment) else {
                return nil
            }

            guard !fragmentCandidates.isEmpty else {
                return []
            }

            if let current = candidates {
                candidates = intersectPostingLists(current, fragmentCandidates)
            } else {
                candidates = fragmentCandidates
            }

            if candidates?.isEmpty == true {
                return []
            }
        }

        return candidates
    }

    private static func wildcardRequiredFragments(from pattern: String) -> [[UInt8]] {
        var fragments: [[UInt8]] = []
        var current: [UInt8] = []

        for byte in pattern.utf8 {
            if byte == 42 || byte == 47 || byte == 63 || byte == 92 {
                if !current.isEmpty {
                    fragments.append(current)
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(byte)
            }
        }

        if !current.isEmpty {
            fragments.append(current)
        }

        return fragments
    }

    private static func pathLiteralFragments(from token: String) -> [[UInt8]] {
        token.split { $0 == "/" || $0 == "\\" }
            .map(String.init)
            .filter { !$0.isEmpty }
            .map { Array($0.utf8) }
    }

    private static func fuzzyTextCandidateIndices(
        snapshot: SearchSnapshot,
        field: FuzzyMatcher.QueryField,
        token: String
    ) -> [Int32]? {
        guard token.utf8.allSatisfy({ $0 < 128 }) else {
            return nil
        }

        let tokenBytes = Array(token.utf8)
        let nameCandidates = fuzzyNameCandidateIndices(snapshot: snapshot, tokenBytes: tokenBytes)

        switch field {
        case .name:
            return nameCandidates
        case .path:
            return snapshot.candidateIndices(containing: tokenBytes)
        case .any:
            guard let nameCandidates else {
                return nil
            }
            if let pathCandidates = snapshot.candidateIndices(containing: tokenBytes) {
                return unionPostingLists(pathCandidates, nameCandidates)
            }
            return nameCandidates
        }
    }

    private static func fuzzyNameCandidateIndices(snapshot: SearchSnapshot, tokenBytes: [UInt8]) -> [Int32]? {
        guard tokenBytes.count >= 4, tokenBytes.count <= 12 else {
            return nil
        }

        var seen = Set<UInt8>()
        var distinctBytes: [UInt8] = []
        distinctBytes.reserveCapacity(tokenBytes.count)

        for byte in tokenBytes where seen.insert(byte).inserted {
            distinctBytes.append(byte)
        }

        guard distinctBytes.count == tokenBytes.count else {
            return nil
        }

        let allowedMissing = tokenBytes.count <= 5 ? 1 : 2
        let requiredCount = distinctBytes.count - allowedMissing
        guard requiredCount >= 3 else {
            return nil
        }

        let requiredSubsets = byteSubsets(distinctBytes, count: requiredCount)
        guard !requiredSubsets.isEmpty else {
            return nil
        }

        return snapshot.candidateNameIndices(containingAny: requiredSubsets)
    }

    private static func byteSubsets(_ bytes: [UInt8], count: Int) -> [[UInt8]] {
        guard count > 0, count <= bytes.count else {
            return []
        }

        var subsets: [[UInt8]] = []
        var current: [UInt8] = []
        current.reserveCapacity(count)

        func appendSubsets(start: Int) {
            if current.count == count {
                subsets.append(current)
                return
            }

            let remainingSlots = count - current.count
            guard bytes.count - start >= remainingSlots else {
                return
            }

            let lastStart = bytes.count - remainingSlots
            for index in start...lastStart {
                current.append(bytes[index])
                appendSubsets(start: index + 1)
                current.removeLast()
            }
        }

        appendSubsets(start: 0)
        return subsets
    }

    private static func tokenContainsPathSeparator(_ token: String) -> Bool {
        token.contains("/") || token.contains("\\")
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
                    guard !pattern.token.isEmpty, !tokenContainsPathSeparator(pattern.token) else { return nil }
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

    private static func unionPostingLists(_ lhs: [Int32], _ rhs: [Int32]) -> [Int32] {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }

        var result: [Int32] = []
        result.reserveCapacity(lhs.count + rhs.count)

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
                result.append(left)
                leftIndex += 1
            } else {
                result.append(right)
                rightIndex += 1
            }
        }

        if leftIndex < lhs.count {
            result.append(contentsOf: lhs[leftIndex...])
        }

        if rightIndex < rhs.count {
            result.append(contentsOf: rhs[rightIndex...])
        }

        return result
    }

    private static func wildcardMatches(_ text: String, pattern: String) -> Bool {
        let textBytes = Array(text.utf8)
        let patternBytes = Array(pattern.utf8)
        guard !patternBytes.isEmpty else { return false }

        var previous = Array(repeating: false, count: textBytes.count + 1)
        previous[0] = true

        for patternByte in patternBytes {
            var current = Array(repeating: false, count: textBytes.count + 1)

            if patternByte == 42 {
                current[0] = previous[0]
                if !textBytes.isEmpty {
                    for index in 1...textBytes.count {
                        current[index] = previous[index] || current[index - 1]
                    }
                }
            } else if !textBytes.isEmpty {
                for index in 1...textBytes.count {
                    current[index] = previous[index - 1] && (patternByte == 63 || patternByte == textBytes[index - 1])
                }
            }

            previous = current
        }

        return previous[textBytes.count]
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

    private func beginSnapshotLoad() -> Bool {
        let didBegin = lock.withLock { () -> Bool in
            guard snapshotLoadState == .notStarted else {
                return false
            }

            snapshotLoadState = .loading
            status = "Loading saved index"
            lastUpdated = Date()
            return true
        }

        if didBegin {
            publishStats()
        }

        return didBegin
    }

    private func loadSnapshotAfterBegin(generationAtStart: UInt64) {
        guard
            let data = try? Data(contentsOf: snapshotURL),
            let persisted = try? JSONDecoder().decode(PersistedSnapshot.self, from: data)
        else {
            let didUpdate = lock.withLock { () -> Bool in
                guard generation == generationAtStart else {
                    return false
                }

                snapshotLoadState = .finished
                status = "No index yet"
                indexing = false
                lastUpdated = Date()
                return true
            }

            if didUpdate {
                publishStats()
            }
            return
        }

        let records = Dictionary(uniqueKeysWithValues: persisted.records.map { ($0.path, $0) })
        let snapshot = SearchSnapshot(records: Array(records.values))
        let didApply = lock.withLock { () -> Bool in
            guard generation == generationAtStart else {
                return false
            }

            recordsByPath = records
            searchSnapshot = snapshot
            searchSnapshotRevision &+= 1
            snapshotLoadState = .finished
            status = "Loaded \(records.count) indexed files"
            indexing = false
            lastUpdated = persisted.savedAt
            return true
        }

        if didApply {
            publishStats()
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

        var fastSnapshot: SearchSnapshot?
        var snapshotRecords: [FileRecord] = []
        var snapshotRevision: UInt64 = 0
        let canUseFastMetadataUpdate = deletedPrefixes.isEmpty && shallowDirectoryChildren.isEmpty

        lock.withLock {
            let previousSnapshot = searchSnapshot

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
            status = "Updated \(upserts.count + deletedPrefixes.count) changed path\(upserts.count + deletedPrefixes.count == 1 ? "" : "s")"
            lastUpdated = Date()

            if canUseFastMetadataUpdate {
                fastSnapshot = previousSnapshot.updatingMetadata(for: upserts)
            }

            if fastSnapshot == nil {
                snapshotRecords = Array(recordsByPath.values)
            }
        }

        if let fastSnapshot {
            lock.withLock {
                if searchSnapshotRevision == snapshotRevision {
                    searchSnapshot = fastSnapshot
                }
            }
            publishStats()
            schedulePersist()
            return
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
                    isLoadingSnapshot: snapshotLoadState == .loading,
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
                isLoadingSnapshot: snapshotLoadState == .loading,
                status: status,
                lastUpdated: lastUpdated
            )
        }
    }

    private func currentGeneration() -> UInt64 {
        lock.withLock {
            generation
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
