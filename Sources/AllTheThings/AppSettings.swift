import Foundation

enum AppSettings {
    static let allowMultipleInstancesKey = "ATTAllowMultipleInstances"
    static let highlightSearchTextKey = "ATTHighlightSearchText"
    static let indexedRootsKey = "ATTIndexedRoots"
    static let indexedRootsInitializedKey = "ATTIndexedRootsInitialized"
    static let indexedRootsDidChangeNotification = Notification.Name("com.allthethings.settings.indexedRootsDidChange")

    static func registerDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            allowMultipleInstancesKey: false,
            highlightSearchTextKey: true
        ])
    }

    static func indexedRoots(defaults: UserDefaults = .standard) -> [URL] {
        let saved = defaults.array(forKey: indexedRootsKey) as? [String] ?? []
        if defaults.bool(forKey: indexedRootsInitializedKey) {
            return saved.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }

        let roots = uniqueRoots(defaultIndexedRoots() + saved.map { URL(fileURLWithPath: $0, isDirectory: true) })
        defaults.set(roots.map(\.path), forKey: indexedRootsKey)
        defaults.set(true, forKey: indexedRootsInitializedKey)
        return roots
    }

    static func saveIndexedRoots(_ roots: [URL], defaults: UserDefaults = .standard) {
        let paths = uniqueRoots(roots).map(\.path)
        defaults.set(paths, forKey: indexedRootsKey)
        defaults.set(true, forKey: indexedRootsInitializedKey)
        defaults.synchronize()
        NotificationCenter.default.post(name: indexedRootsDidChangeNotification, object: defaults)
    }

    static func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    static func displayPath(_ url: URL) -> String {
        displayPath(url.standardizedFileURL.path)
    }

    private static func defaultIndexedRoots() -> [URL] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Developer", isDirectory: true),
            URL(fileURLWithPath: "/Applications", isDirectory: true)
        ]

        return candidates.filter { fileManager.fileExists(atPath: $0.path) }
    }

    private static func uniqueRoots(_ roots: [URL]) -> [URL] {
        var seen = Set<String>()
        var unique: [URL] = []
        unique.reserveCapacity(roots.count)

        for root in roots {
            let standardized = root.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { continue }
            unique.append(standardized)
        }

        return unique
    }
}
