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
        let aliases: [AppAlias]
    }

    private struct AppAlias {
        let value: String
        let source: String
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

            let appNameMatch = queryIsEmpty ? nil : Self.appNameExplanation(
                record: entry.record,
                query: trimmedQuery
            )
            let recordMatch = queryIsEmpty ? nil : FuzzyMatcher.explain(record: entry.record, query: trimmedQuery)
            let aliasMatch = queryIsEmpty ? nil : Self.aliasExplanation(
                aliases: entry.aliases,
                query: trimmedQuery
            )
            let match = Self.bestAppExplanation(
                appNameMatch: appNameMatch,
                recordMatch: recordMatch,
                aliasMatch: aliasMatch
            )
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
                    entries.append(AppEntry(
                        record: record,
                        rootPath: root.path,
                        aliases: Self.aliases(for: root, record: record)
                    ))
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
                    entries.append(AppEntry(
                        record: record,
                        rootPath: rootPath,
                        aliases: Self.aliases(for: standardized, record: record)
                    ))
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

    private static func bestExplanation(_ lhs: MatchExplanation?, _ rhs: MatchExplanation?) -> MatchExplanation? {
        switch (lhs, rhs) {
        case (nil, nil):
            return nil
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case let (lhs?, rhs?):
            if lhs.quality != rhs.quality {
                return lhs.quality > rhs.quality ? lhs : rhs
            }
            return lhs.score >= rhs.score ? lhs : rhs
        }
    }

    private static func bestAppExplanation(
        appNameMatch: MatchExplanation?,
        recordMatch: MatchExplanation?,
        aliasMatch: MatchExplanation?
    ) -> MatchExplanation? {
        if appNameMatch?.matchClass == .exact || appNameMatch?.matchClass == .prefix {
            return appNameMatch
        }

        return bestExplanation(bestExplanation(appNameMatch, recordMatch), aliasMatch)
    }

    private static func appNameExplanation(record: FileRecord, query: String) -> MatchExplanation? {
        let appName = record.name.removingAppExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAppName = FuzzyMatcher.normalize(appName)
        let normalizedQuery = FuzzyMatcher.normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !normalizedAppName.isEmpty, !normalizedQuery.isEmpty else { return nil }

        if normalizedAppName == normalizedQuery {
            return MatchExplanation(
                matchClass: .exact,
                score: 11_800,
                field: .name,
                reason: "App name exactly matched \"\(query)\"",
                spans: [
                    MatchSpan(
                        field: .name,
                        location: 0,
                        length: appName.utf16.count,
                        style: .contiguous
                    )
                ]
            )
        }

        if normalizedAppName.hasPrefix(normalizedQuery) {
            return MatchExplanation(
                matchClass: .prefix,
                score: 9_700,
                field: .name,
                reason: "App name starts with \"\(query)\"",
                spans: [
                    MatchSpan(
                        field: .name,
                        location: 0,
                        length: min(appName.utf16.count, query.utf16.count),
                        style: .contiguous
                    )
                ]
            )
        }

        return nil
    }

    private static func aliasExplanation(aliases: [AppAlias], query: String) -> MatchExplanation? {
        let normalizedQuery = compactAlias(query)
        guard !normalizedQuery.isEmpty else { return nil }

        var best: MatchExplanation?
        for alias in aliases {
            let explanation: MatchExplanation?
            if alias.value == normalizedQuery {
                explanation = MatchExplanation(
                    matchClass: .alias,
                    score: 12_000,
                    field: .name,
                    reason: "App alias from \(alias.source) exactly matched \"\(query)\""
                )
            } else if alias.value.hasPrefix(normalizedQuery) {
                explanation = MatchExplanation(
                    matchClass: .alias,
                    score: 9_900 - min(alias.value.count, 300),
                    field: .name,
                    reason: "App alias from \(alias.source) starts with \"\(query)\""
                )
            } else {
                explanation = nil
            }

            best = bestExplanation(best, explanation)
        }

        return best
    }

    private static func aliases(for appURL: URL, record: FileRecord) -> [AppAlias] {
        var builder = AliasBuilder()
        builder.addNameAliases(record.name.removingAppExtension, source: "app name")

        guard let info = infoPlist(for: appURL) else {
            return builder.aliases
        }

        if let identifier = stringValue(for: "CFBundleIdentifier", in: info) {
            for component in identifierComponents(identifier) {
                builder.add(component, source: "bundle identifier")
            }
        }

        for key in ["CFBundleDisplayName", "CFBundleName", "CFBundleExecutable"] {
            if let value = stringValue(for: key, in: info) {
                builder.addNameAliases(value, source: key)
            }
        }

        for urlType in urlTypes(in: info) {
            if let urlName = stringValue(for: "CFBundleURLName", in: urlType) {
                builder.addNameAliases(urlName, source: "URL name")
            }
            for scheme in stringArrayValue(for: "CFBundleURLSchemes", in: urlType) {
                builder.add(scheme, source: "URL scheme")
            }
        }

        return builder.aliases
    }

    private static func infoPlist(for appURL: URL) -> [String: Any]? {
        let infoURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard
            let data = try? Data(contentsOf: infoURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let dictionary = plist as? [String: Any]
        else {
            return nil
        }

        return dictionary
    }

    private static func urlTypes(in info: [String: Any]) -> [[String: Any]] {
        guard let types = info["CFBundleURLTypes"] else { return [] }
        if let dictionaries = types as? [[String: Any]] {
            return dictionaries
        }
        if let dictionaries = types as? [NSDictionary] {
            return dictionaries.compactMap { $0 as? [String: Any] }
        }
        return []
    }

    private static func stringValue(for key: String, in dictionary: [String: Any]) -> String? {
        guard let value = dictionary[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stringArrayValue(for key: String, in dictionary: [String: Any]) -> [String] {
        guard let values = dictionary[key] else { return [] }
        if let strings = values as? [String] {
            return strings
        }
        if let strings = values as? NSArray {
            return strings.compactMap { $0 as? String }
        }
        return []
    }

    private static func identifierComponents(_ identifier: String) -> [String] {
        let ignored = Set(["com", "org", "net", "io", "app", "apps"])
        return identifier
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !ignored.contains(compactAlias($0)) }
    }

    private static func generatedNameAliases(from value: String) -> [String] {
        let words = aliasWords(from: value)
        guard !words.isEmpty else { return [] }

        var aliases: [String] = []
        aliases.append(words.joined())

        if words.count > 1 {
            aliases.append(words.map { String($0.prefix(1)) }.joined())
        }

        if words.count > 2, let last = words.last {
            aliases.append(words.dropLast().map { String($0.prefix(1)) }.joined() + last)
        }

        return aliases
    }

    private static func aliasWords(from value: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previousWasLowercaseOrDigit = false

        func appendCurrent() {
            guard !current.isEmpty else { return }
            words.append(current)
            current = ""
        }

        for scalar in value.unicodeScalars {
            let character = Character(scalar)
            if CharacterSet.alphanumerics.contains(scalar) {
                let string = String(character)
                let isUppercase = string.rangeOfCharacter(from: .uppercaseLetters) != nil
                let isLowercaseOrDigit = string.rangeOfCharacter(from: .lowercaseLetters) != nil
                    || string.rangeOfCharacter(from: .decimalDigits) != nil
                if isUppercase, previousWasLowercaseOrDigit {
                    appendCurrent()
                }
                current += string.lowercased()
                previousWasLowercaseOrDigit = isLowercaseOrDigit
            } else {
                appendCurrent()
                previousWasLowercaseOrDigit = false
            }
        }
        appendCurrent()

        return words
    }

    private static func compactAlias(_ value: String) -> String {
        FuzzyMatcher.normalize(value)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private struct AliasBuilder {
        private var seen = Set<String>()
        private(set) var aliases: [AppAlias] = []

        mutating func add(_ value: String, source: String) {
            let alias = ApplicationSearchCatalog.compactAlias(value)
            guard alias.count >= 2, seen.insert(alias).inserted else { return }
            aliases.append(AppAlias(value: alias, source: source))
        }

        mutating func addNameAliases(_ value: String, source: String) {
            add(value, source: source)
            for alias in ApplicationSearchCatalog.generatedNameAliases(from: value) {
                add(alias, source: source)
            }
        }
    }
}

private extension String {
    var removingAppExtension: String {
        guard lowercased().hasSuffix(".app") else { return self }
        return String(dropLast(4))
    }
}
