import Foundation
import ATTCore

enum AppSettings {
    static let allowMultipleInstancesKey = "ATTAllowMultipleInstances"
    static let highlightSearchTextKey = "ATTHighlightSearchText"
    static let showHiddenFilesKey = "ATTShowHiddenFiles"
    static let indexedRootsKey = "ATTIndexedRoots"
    static let indexedRootsInitializedKey = "ATTIndexedRootsInitialized"
    static let exclusionPatternsKey = "ATTExclusionPatterns"
    static let exclusionDefaultsVersionKey = "ATTExclusionDefaultsVersion"
    static let indexedRootsDidChangeNotification = Notification.Name("com.allthethings.settings.indexedRootsDidChange")
    static let exclusionPatternsDidChangeNotification = Notification.Name("com.allthethings.settings.exclusionPatternsDidChange")

    private static let currentExclusionDefaultsVersion = 3
    private static let versionOneDefaultExclusionPatterns = [
        "node_modules/",
        "DerivedData/",
        ".git/objects/",
        "Library/Caches/",
        ".Trash/"
    ]
    private static let retiredVersionTwoDefaultExclusionPatterns = [
        "bower_components/",
        "vendor/bundle/",
        "Pods/",
        "Carthage/Build/",
        ".build/",
        "build/",
        "dist/",
        "out/",
        "target/",
        "CMakeFiles/",
        "cmake-build-*/",
        ".gradle/",
        ".next/",
        ".nuxt/",
        ".venv/",
        "venv/"
    ]

    static func registerDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            allowMultipleInstancesKey: false,
            highlightSearchTextKey: true,
            showHiddenFilesKey: false,
            exclusionPatternsKey: FileExclusionRules.defaultPatterns
        ])
        migrateExclusionDefaults(defaults)
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

    static func resetIndexedRoots(defaults: UserDefaults = .standard) {
        saveIndexedRoots(defaultIndexedRoots(), defaults: defaults)
    }

    static func exclusionPatterns(defaults: UserDefaults = .standard) -> [String] {
        defaults.array(forKey: exclusionPatternsKey) as? [String] ?? FileExclusionRules.defaultPatterns
    }

    static func saveExclusionPatterns(_ patterns: [String], defaults: UserDefaults = .standard) {
        defaults.set(patterns, forKey: exclusionPatternsKey)
        defaults.synchronize()
        NotificationCenter.default.post(name: exclusionPatternsDidChangeNotification, object: defaults)
    }

    static func resetExclusionPatterns(defaults: UserDefaults = .standard) {
        saveExclusionPatterns(FileExclusionRules.defaultPatterns, defaults: defaults)
    }

    static func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    static func displayPath(_ url: URL) -> String {
        displayPath(url.standardizedFileURL.path)
    }

    static func defaultIndexedRoots() -> [URL] {
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

    private static func migrateExclusionDefaults(_ defaults: UserDefaults) {
        let currentVersion = defaults.integer(forKey: exclusionDefaultsVersionKey)
        guard currentVersion < currentExclusionDefaultsVersion else { return }

        var patterns = exclusionPatterns(defaults: defaults)
        var didChangePatterns = false

        if currentVersion < 3 {
            let retiredPatterns = Set(retiredVersionTwoDefaultExclusionPatterns)
            let filteredPatterns = patterns.filter { !retiredPatterns.contains($0) }
            if filteredPatterns.count != patterns.count {
                patterns = filteredPatterns
                didChangePatterns = true
            }
        }

        let additions = defaultExclusionPatternsAdded(after: currentVersion)
        if !additions.isEmpty {
            var existingPatterns = Set(patterns)

            for pattern in additions where existingPatterns.insert(pattern).inserted {
                patterns.append(pattern)
                didChangePatterns = true
            }
        }

        if didChangePatterns {
            defaults.set(patterns, forKey: exclusionPatternsKey)
        }

        defaults.set(currentExclusionDefaultsVersion, forKey: exclusionDefaultsVersionKey)
        defaults.synchronize()
    }

    private static func defaultExclusionPatternsAdded(after version: Int) -> [String] {
        guard version < 2 else { return [] }
        return FileExclusionRules.defaultPatterns.filter { !versionOneDefaultExclusionPatterns.contains($0) }
    }
}
