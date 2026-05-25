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
    public var onStatsChanged: ((IndexStats) -> Void)?

    private struct PersistedSnapshot: Codable {
        let savedAt: Date
        let records: [FileRecord]
    }

    private let lock = NSLock()
    private let fileManager: FileManager
    private let snapshotURL: URL
    private let persistenceQueue = DispatchQueue(label: "att.index.persistence", qos: .utility)
    private var recordsByPath: [String: FileRecord] = [:]
    private var roots: [String] = []
    private var generation: UInt64 = 0
    private var persistRevision: UInt64 = 0
    private var indexing = false
    private var status = "Starting"
    private var lastUpdated = Date()

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
        let started = Date()
        let records = lock.withLock {
            Array(recordsByPath.values)
        }

        let trimmedQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        var matches: [SearchResult] = []
        matches.reserveCapacity(min(records.count, maxResults))

        if trimmedQuery.isEmpty {
            matches = records.map { SearchResult(record: $0, score: 0) }
        } else {
            for record in records {
                if let score = FuzzyMatcher.score(record: record, query: trimmedQuery) {
                    matches.append(SearchResult(record: record, score: score))
                }
            }
        }

        let total = matches.count
        matches.sort { lhs, rhs in
            Self.compare(lhs, rhs, sort: request.sort, queryIsEmpty: trimmedQuery.isEmpty)
        }

        if matches.count > maxResults {
            matches.removeSubrange(maxResults..<matches.count)
        }

        return SearchResponse(results: matches, totalMatches: total, elapsed: Date().timeIntervalSince(started))
    }

    public func deleteSnapshot() {
        lock.withLock {
            recordsByPath.removeAll(keepingCapacity: true)
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
        lock.withLock {
            recordsByPath = records
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

        func publishPartial(force: Bool = false) {
            guard isCurrentGeneration(currentGeneration) else { return }
            let now = Date()
            guard force || now.timeIntervalSince(lastPublish) > 0.25 else { return }
            lastPublish = now
            replaceRecords(localRecords, isIndexing: true, status: "Indexing \(visited.formatted()) files")
        }

        for root in rootURLs {
            guard isCurrentGeneration(currentGeneration) else { return }
            scan(root: root, into: &localRecords, visited: &visited) {
                publishPartial()
            }
            publishPartial(force: true)
        }

        guard isCurrentGeneration(currentGeneration) else { return }
        replaceRecords(localRecords, isIndexing: false, status: "Indexed \(localRecords.count.formatted()) files")
        schedulePersist()
    }

    private func scan(
        root: URL,
        into records: inout [String: FileRecord],
        visited: inout Int,
        progress: () -> Void
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
                progress()
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

            status = "Updated \(upserts.count + deletedPrefixes.count) changed path\(upserts.count + deletedPrefixes.count == 1 ? "" : "s")"
            lastUpdated = Date()
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
        lock.withLock {
            recordsByPath = records
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
        onStatsChanged?(lockedStats())
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
