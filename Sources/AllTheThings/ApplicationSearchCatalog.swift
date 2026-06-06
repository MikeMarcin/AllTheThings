import ATTCore
import Foundation

struct ApplicationSearchQuery: Equatable, Sendable {
    let searchText: String

    static func parse(_ query: String) -> ApplicationSearchQuery? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }

        let prefix = trimmed[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["app", "apps", "application", "applications"].contains(prefix) else { return nil }

        let valueStart = trimmed.index(after: colon)
        let value = trimmed[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        return ApplicationSearchQuery(searchText: String(value))
    }
}

final class ApplicationSearchCatalog: @unchecked Sendable {
    private struct AppEntry {
        let record: FileRecord
        let rootPath: String
    }

    private let fileManager: FileManager
    private let lock = NSLock()
    private var cachedRootPaths: [String] = []
    private var cachedEntries: [AppEntry] = []

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cachedRootPaths = []
        cachedEntries = []
    }

    func search(
        queryText: String,
        roots: [URL],
        sort: SortSpec,
        maxResults: Int = 2_000,
        shouldCancel: () -> Bool = { false }
    ) -> SearchResponse? {
        let startedAt = Date()
        let entries = appEntries(for: roots)
        guard !shouldCancel() else { return nil }

        let trimmedQuery = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryIsEmpty = trimmedQuery.isEmpty
        var results: [SearchResult] = []
        results.reserveCapacity(min(entries.count, max(maxResults, 0)))

        for entry in entries {
            if shouldCancel() {
                return nil
            }

            let match = queryIsEmpty ? nil : FuzzyMatcher.explain(record: entry.record, query: trimmedQuery)
            guard queryIsEmpty || match != nil else { continue }

            results.append(SearchResult(
                record: entry.record,
                score: match?.score ?? 0,
                match: match,
                rootPath: entry.rootPath
            ))
        }

        let totalMatches = results.count
        results.sort { lhs, rhs in
            Self.compare(lhs, rhs, sort: sort, queryIsEmpty: queryIsEmpty)
        }
        if maxResults >= 0, results.count > maxResults {
            results = Array(results.prefix(maxResults))
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        return SearchResponse(
            results: results,
            totalMatches: totalMatches,
            elapsed: elapsed,
            snapshotRevision: nil,
            usesIndexedCandidates: true,
            executionProfile: SearchExecutionProfile(
                executionPath: .applicationCatalog,
                indexesUsed: [.applicationCatalog],
                candidateCount: entries.count,
                scannedRowCount: entries.count,
                elapsed: elapsed
            )
        )
    }

    private func appEntries(for roots: [URL]) -> [AppEntry] {
        lock.lock()
        defer { lock.unlock() }

        let standardizedRoots = roots.map(\.standardizedFileURL)
        let rootPaths = standardizedRoots.map(\.path)
        guard rootPaths != cachedRootPaths else {
            return cachedEntries
        }

        var entries: [AppEntry] = []
        var seenAppPaths = Set<String>()

        for root in standardizedRoots {
            if root.pathExtension.lowercased() == "app" {
                guard seenAppPaths.insert(root.path).inserted else { continue }
                if let record = FileRecord(url: root) {
                    entries.append(AppEntry(record: record, rootPath: root.path))
                }
                continue
            }

            scan(root, rootPath: root.path, entries: &entries, seenAppPaths: &seenAppPaths)
        }

        entries.sort { lhs, rhs in
            if lhs.record.normalizedName != rhs.record.normalizedName {
                return lhs.record.normalizedName < rhs.record.normalizedName
            }
            return lhs.record.path < rhs.record.path
        }
        cachedRootPaths = rootPaths
        cachedEntries = entries
        return entries
    }

    private func scan(
        _ directory: URL,
        rootPath: String,
        entries: inout [AppEntry],
        seenAppPaths: inout Set<String>
    ) {
        let children = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(FileRecord.resourceKeys),
            options: [.skipsHiddenFiles]
        )) ?? []

        for child in children.sorted(by: { $0.path < $1.path }) {
            guard let values = try? child.resourceValues(forKeys: FileRecord.resourceKeys) else { continue }
            let isDirectory = values.isDirectory ?? false
            guard isDirectory else { continue }

            let standardized = child.standardizedFileURL
            if standardized.pathExtension.lowercased() == "app" {
                guard seenAppPaths.insert(standardized.path).inserted else { continue }
                if let record = FileRecord(url: standardized, resourceValues: values) {
                    entries.append(AppEntry(record: record, rootPath: rootPath))
                }
                continue
            }

            scan(standardized, rootPath: rootPath, entries: &entries, seenAppPaths: &seenAppPaths)
        }
    }

    private static func compare(_ lhs: SearchResult, _ rhs: SearchResult, sort: SortSpec, queryIsEmpty: Bool) -> Bool {
        let ascending = sort.ascending

        func ordered<T: Comparable>(_ left: T, _ right: T) -> Bool? {
            guard left != right else { return nil }
            return ascending ? left < right : left > right
        }

        if !queryIsEmpty {
            let lhsQuality = lhs.match?.quality ?? MatchQuality(matchClass: .metadata, scoreBin: 0)
            let rhsQuality = rhs.match?.quality ?? MatchQuality(matchClass: .metadata, scoreBin: 0)
            if lhsQuality != rhsQuality {
                return lhsQuality > rhsQuality
            }
        }

        let primary: Bool?
        switch sort.column {
        case .relevance:
            if queryIsEmpty {
                primary = ordered(lhs.record.modifiedTime, rhs.record.modifiedTime)
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
            primary = ordered(kindName(for: lhs.record), kindName(for: rhs.record))
        case .volume:
            primary = ordered(lhs.record.volumeName, rhs.record.volumeName)
        case .root:
            primary = ordered(lhs.rootPath ?? "", rhs.rootPath ?? "")
        }

        if let primary {
            return primary
        }

        if lhs.record.normalizedName != rhs.record.normalizedName {
            return lhs.record.normalizedName < rhs.record.normalizedName
        }

        return lhs.record.path < rhs.record.path
    }

    private static func kindName(for record: FileRecord) -> String {
        record.isDirectory && record.fileExtension == "app" ? "Application" : (record.isDirectory ? "Folder" : "File")
    }
}
