import Foundation
import ATTCore

enum AppThemePreference: String, CaseIterable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum AppSettings {
    static let allowMultipleInstancesKey = "ATTAllowMultipleInstances"
    static let globalSearchHotKeyEnabledKey = "ATTGlobalSearchHotKeyEnabled"
    static let globalSearchHotKeyConfirmationResolvedKey = "ATTGlobalSearchHotKeyConfirmationResolved"
    static let globalSearchHotKeyKeyCodeKey = "ATTGlobalSearchHotKeyKeyCode"
    static let globalSearchHotKeyModifierFlagsKey = "ATTGlobalSearchHotKeyModifierFlags"
    static let fullDiskAccessOnboardingShownKey = "ATTFullDiskAccessOnboardingShown"
    static let highlightSearchTextKey = "ATTHighlightSearchText"
    static let menuBarIconEnabledKey = "ATTMenuBarIconEnabled"
    static let showHiddenFilesKey = "ATTShowHiddenFiles"
    static let themePreferenceKey = "ATTThemePreference"
    static let appFontFamilyNameKey = "ATTAppFontFamilyName"
    static let appFontSizeKey = "ATTAppFontSize"
    static let lightMatchColorsKey = "ATTLightMatchColors"
    static let darkMatchColorsKey = "ATTDarkMatchColors"
    static let indexedRootsKey = "ATTIndexedRoots"
    static let indexedRootsInitializedKey = "ATTIndexedRootsInitialized"
    static let indexingSetupCompletedKey = "ATTIndexingSetupCompleted"
    static let exclusionPatternsKey = "ATTExclusionPatterns"
    static let exclusionDefaultsVersionKey = "ATTExclusionDefaultsVersion"
    static let globalSearchHotKeyDidChangeNotification = Notification.Name("com.allthethings.settings.globalSearchHotKeyDidChange")
    static let menuBarIconDidChangeNotification = Notification.Name("com.allthethings.settings.menuBarIconDidChange")
    static let themePreferenceDidChangeNotification = Notification.Name("com.allthethings.settings.themePreferenceDidChange")
    static let appFontDidChangeNotification = Notification.Name("com.allthethings.settings.appFontDidChange")
    static let matchColorsDidChangeNotification = Notification.Name("com.allthethings.settings.matchColorsDidChange")
    static let indexedRootsDidChangeNotification = Notification.Name("com.allthethings.settings.indexedRootsDidChange")
    static let exclusionPatternsDidChangeNotification = Notification.Name("com.allthethings.settings.exclusionPatternsDidChange")

    private static let currentExclusionDefaultsVersion = 8
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
            globalSearchHotKeyEnabledKey: true,
            globalSearchHotKeyConfirmationResolvedKey: false,
            globalSearchHotKeyKeyCodeKey: Int(GlobalHotKey.defaultSearch.keyCode),
            globalSearchHotKeyModifierFlagsKey: Int(GlobalHotKey.defaultSearch.modifiers),
            fullDiskAccessOnboardingShownKey: false,
            highlightSearchTextKey: true,
            menuBarIconEnabledKey: true,
            showHiddenFilesKey: false,
            themePreferenceKey: AppThemePreference.system.rawValue,
            appFontFamilyNameKey: "",
            appFontSizeKey: Double(defaultAppFontSize),
            lightMatchColorsKey: defaultMatchColorHexes(isDark: false),
            darkMatchColorsKey: defaultMatchColorHexes(isDark: true),
            exclusionPatternsKey: FileExclusionRules.defaultPatterns
        ])
        migrateExclusionDefaults(defaults)
    }

    static func themePreference(defaults: UserDefaults = .standard) -> AppThemePreference {
        guard
            let rawValue = defaults.string(forKey: themePreferenceKey),
            let preference = AppThemePreference(rawValue: rawValue)
        else {
            return .system
        }

        return preference
    }

    static func saveThemePreference(_ preference: AppThemePreference, defaults: UserDefaults = .standard) {
        guard themePreference(defaults: defaults) != preference else { return }

        defaults.set(preference.rawValue, forKey: themePreferenceKey)
        defaults.synchronize()
        NotificationCenter.default.post(name: themePreferenceDidChangeNotification, object: defaults)
    }

    static func globalSearchHotKeyEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: globalSearchHotKeyEnabledKey)
    }

    static func globalSearchHotKeyNeedsConfirmation(defaults: UserDefaults = .standard) -> Bool {
        globalSearchHotKeyEnabled(defaults: defaults)
            && !defaults.bool(forKey: globalSearchHotKeyConfirmationResolvedKey)
    }

    static func globalSearchHotKey(defaults: UserDefaults = .standard) -> GlobalHotKey {
        let keyCode = defaults.integer(forKey: globalSearchHotKeyKeyCodeKey)
        let modifiers = defaults.integer(forKey: globalSearchHotKeyModifierFlagsKey)
        let hotKey = GlobalHotKey(keyCode: UInt32(max(0, keyCode)), modifiers: UInt32(max(0, modifiers)))

        return hotKey.isValid ? hotKey : .defaultSearch
    }

    static func saveGlobalSearchHotKey(
        enabled: Bool,
        hotKey: GlobalHotKey,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: globalSearchHotKeyEnabledKey)
        defaults.set(true, forKey: globalSearchHotKeyConfirmationResolvedKey)
        defaults.set(Int(hotKey.keyCode), forKey: globalSearchHotKeyKeyCodeKey)
        defaults.set(Int(hotKey.modifiers), forKey: globalSearchHotKeyModifierFlagsKey)
        defaults.synchronize()
        NotificationCenter.default.post(name: globalSearchHotKeyDidChangeNotification, object: defaults)
    }

    static func menuBarIconEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: menuBarIconEnabledKey)
    }

    static func saveMenuBarIconEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        guard menuBarIconEnabled(defaults: defaults) != enabled else { return }

        defaults.set(enabled, forKey: menuBarIconEnabledKey)
        defaults.synchronize()
        NotificationCenter.default.post(name: menuBarIconDidChangeNotification, object: defaults)
    }

    static func indexedRoots(defaults: UserDefaults = .standard) -> [URL] {
        guard indexedRootsConfigured(defaults: defaults) else {
            return []
        }

        return uniqueRoots(savedIndexedRootURLs(defaults: defaults))
    }

    static func indexedRootsConfigured(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: indexedRootsInitializedKey)
            || !(defaults.array(forKey: indexedRootsKey) as? [String] ?? []).isEmpty
    }

    static func indexingSetupCompleted(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: indexingSetupCompletedKey) != nil else {
            return indexedRootsConfigured(defaults: defaults)
        }

        return defaults.bool(forKey: indexingSetupCompletedKey)
    }

    static func saveIndexedRoots(_ roots: [URL], defaults: UserDefaults = .standard) {
        let paths = uniqueRoots(roots).map(\.path)
        defaults.set(paths, forKey: indexedRootsKey)
        defaults.set(true, forKey: indexedRootsInitializedKey)
        defaults.synchronize()
        NotificationCenter.default.post(name: indexedRootsDidChangeNotification, object: defaults)
    }

    static func resetIndexedRoots(defaults: UserDefaults = .standard) {
        saveIndexedRoots(suggestedDefaultIndexedRoots(), defaults: defaults)
    }

    static func initializeIndexedRootsWithDefaultsIfNeeded(defaults: UserDefaults = .standard) {
        guard !indexedRootsConfigured(defaults: defaults) else { return }

        defaults.set(false, forKey: indexingSetupCompletedKey)
        resetIndexedRoots(defaults: defaults)
    }

    static func markIndexingSetupCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: indexingSetupCompletedKey)
        defaults.synchronize()
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
        suggestedDefaultIndexedRoots()
    }

    static func suggestedDefaultIndexedRoots() -> [URL] {
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

    private static func savedIndexedRootURLs(defaults: UserDefaults) -> [URL] {
        (defaults.array(forKey: indexedRootsKey) as? [String] ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
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
        if version < 2 {
            return FileExclusionRules.defaultPatterns.filter { !versionOneDefaultExclusionPatterns.contains($0) }
        }
        var additions: [String] = []
        if version < 4 {
            additions.append("Engine/Binaries/ThirdParty/DotNet/")
        }
        if version < 5 {
            additions.append("Engine/Binaries/ThirdParty/Python3/")
            additions.append(".build/**/index/store/")
        }
        if version < 6 {
            additions.append("Engine/Content/")
            additions.append("Engine/DerivedDataCache/")
            additions.append("Engine/Intermediate/")
            additions.append("Engine/Saved/")
            additions.append("Engine/Source/ThirdParty/")
            additions.append("Engine/Source/Runtime/Engine/Private/")
            additions.append("build/.cmake/api/")
            additions.append("build/_deps/")
            additions.append(".venv/")
            additions.append("venv/")
            additions.append(".tox/")
        }
        if version < 7 {
            additions.append("*.app/Contents/_CodeSignature/")
            additions.append("Xcode.app/Contents/Developer/Platforms/")
            additions.append("Xcode.app/Contents/Developer/Toolchains/")
        }
        if version < 8 {
            additions.append("thirdparty/")
            additions.append("third_party/")
            additions.append("vendor/")
        }
        return additions
    }
}
