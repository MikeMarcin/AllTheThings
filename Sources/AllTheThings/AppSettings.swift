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

enum AppStatusFooterMode: String, CaseIterable {
    case simple
    case detailed

    var title: String {
        switch self {
        case .simple: "Simple"
        case .detailed: "Detailed"
        }
    }
}

enum AppSettings {
    static let allowMultipleInstancesKey = "ATTAllowMultipleInstances"
    static let globalSearchHotKeyEnabledKey = "ATTGlobalSearchHotKeyEnabled"
    static let globalSearchHotKeyConfirmationResolvedKey = "ATTGlobalSearchHotKeyConfirmationResolved"
    static let globalSearchHotKeyKeyCodeKey = "ATTGlobalSearchHotKeyKeyCode"
    static let globalSearchHotKeyModifierFlagsKey = "ATTGlobalSearchHotKeyModifierFlags"
    static let globalAppSearchHotKeyEnabledKey = "ATTGlobalAppSearchHotKeyEnabled"
    static let globalAppSearchHotKeyConfirmationResolvedKey = "ATTGlobalAppSearchHotKeyConfirmationResolved"
    static let globalAppSearchHotKeyKeyCodeKey = "ATTGlobalAppSearchHotKeyKeyCode"
    static let globalAppSearchHotKeyModifierFlagsKey = "ATTGlobalAppSearchHotKeyModifierFlags"
    static let fullDiskAccessOnboardingShownKey = "ATTFullDiskAccessOnboardingShown"
    static let highlightSearchTextKey = "ATTHighlightSearchText"
    static let menuBarIconEnabledKey = "ATTMenuBarIconEnabled"
    static let showHiddenFilesKey = "ATTShowHiddenFiles"
    static let statusFooterModeKey = "ATTStatusFooterMode"
    static let themePreferenceKey = "ATTThemePreference"
    static let appFontFamilyNameKey = "ATTAppFontFamilyName"
    static let appFontSizeKey = "ATTAppFontSize"
    static let diagnosticLogLevelKey = "ATTDiagnosticLogLevel"
    static let lightMatchColorsKey = "ATTLightMatchColors"
    static let darkMatchColorsKey = "ATTDarkMatchColors"
    static let indexedRootsKey = "ATTIndexedRoots"
    static let indexedRootsInitializedKey = "ATTIndexedRootsInitialized"
    static let appSearchRootsKey = "ATTAppSearchRoots"
    static let appSearchRootsInitializedKey = "ATTAppSearchRootsInitialized"
    static let indexingSetupCompletedKey = "ATTIndexingSetupCompleted"
    static let exclusionPatternsKey = "ATTExclusionPatterns"
    static let exclusionDefaultsVersionKey = "ATTExclusionDefaultsVersion"
    static let globalSearchHotKeyDidChangeNotification = Notification.Name("com.allthethings.settings.globalSearchHotKeyDidChange")
    static let globalAppSearchHotKeyDidChangeNotification = Notification.Name("com.allthethings.settings.globalAppSearchHotKeyDidChange")
    static let menuBarIconDidChangeNotification = Notification.Name("com.allthethings.settings.menuBarIconDidChange")
    static let statusFooterModeDidChangeNotification = Notification.Name("com.allthethings.settings.statusFooterModeDidChange")
    static let themePreferenceDidChangeNotification = Notification.Name("com.allthethings.settings.themePreferenceDidChange")
    static let appFontDidChangeNotification = Notification.Name("com.allthethings.settings.appFontDidChange")
    static let diagnosticLogLevelDidChangeNotification = Notification.Name("com.allthethings.settings.diagnosticLogLevelDidChange")
    static let matchColorsDidChangeNotification = Notification.Name("com.allthethings.settings.matchColorsDidChange")
    static let indexedRootsDidChangeNotification = Notification.Name("com.allthethings.settings.indexedRootsDidChange")
    static let appSearchRootsDidChangeNotification = Notification.Name("com.allthethings.settings.appSearchRootsDidChange")
    static let exclusionPatternsDidChangeNotification = Notification.Name("com.allthethings.settings.exclusionPatternsDidChange")

    private static let currentExclusionDefaultsVersion = 10
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
    private static let retiredSearchableUnrealDefaultExclusionPatterns = [
        "Engine/Content/",
        "Engine/Source/ThirdParty/",
        "Engine/Source/Runtime/Engine/Private/",
        "thirdparty/",
        "third_party/",
        "vendor/"
    ]

    private final class SettingsNotificationObject: @unchecked Sendable {
        let defaults: UserDefaults

        init(defaults: UserDefaults) {
            self.defaults = defaults
        }
    }

    static func postSettingsDidChangeNotification(_ name: Notification.Name, defaults: UserDefaults) {
        guard !Thread.isMainThread else {
            NotificationCenter.default.post(name: name, object: defaults)
            return
        }

        let object = SettingsNotificationObject(defaults: defaults)
        DispatchQueue.main.sync {
            NotificationCenter.default.post(name: name, object: object.defaults)
        }
    }

    static func registerDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            allowMultipleInstancesKey: false,
            globalSearchHotKeyEnabledKey: true,
            globalSearchHotKeyConfirmationResolvedKey: false,
            globalSearchHotKeyKeyCodeKey: Int(GlobalHotKey.defaultSearch.keyCode),
            globalSearchHotKeyModifierFlagsKey: Int(GlobalHotKey.defaultSearch.modifiers),
            globalAppSearchHotKeyEnabledKey: true,
            globalAppSearchHotKeyConfirmationResolvedKey: false,
            globalAppSearchHotKeyKeyCodeKey: Int(GlobalHotKey.defaultAppSearch.keyCode),
            globalAppSearchHotKeyModifierFlagsKey: Int(GlobalHotKey.defaultAppSearch.modifiers),
            fullDiskAccessOnboardingShownKey: false,
            highlightSearchTextKey: true,
            menuBarIconEnabledKey: true,
            showHiddenFilesKey: false,
            statusFooterModeKey: AppStatusFooterMode.simple.rawValue,
            themePreferenceKey: AppThemePreference.system.rawValue,
            appFontFamilyNameKey: "",
            appFontSizeKey: Double(defaultAppFontSize),
            diagnosticLogLevelKey: DiagnosticLogLevel.info.rawValue,
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
        DiagnosticLogger.shared.log(
            category: "settings",
            event: "settings.themeChanged",
            fields: [
                "theme": .publicString(preference.rawValue)
            ]
        )
        postSettingsDidChangeNotification(themePreferenceDidChangeNotification, defaults: defaults)
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
        DiagnosticLogger.shared.log(
            category: "settings",
            event: "settings.globalSearchHotKeyChanged",
            fields: [
                "enabled": .publicBool(enabled),
                "keyCode": .publicInt(Int(hotKey.keyCode)),
                "modifiers": .publicInt(Int(hotKey.modifiers))
            ]
        )
        postSettingsDidChangeNotification(globalSearchHotKeyDidChangeNotification, defaults: defaults)
    }

    static func globalAppSearchHotKeyEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: globalAppSearchHotKeyEnabledKey)
    }

    static func globalAppSearchHotKeyNeedsConfirmation(defaults: UserDefaults = .standard) -> Bool {
        globalAppSearchHotKeyEnabled(defaults: defaults)
            && !defaults.bool(forKey: globalAppSearchHotKeyConfirmationResolvedKey)
    }

    static func globalAppSearchHotKey(defaults: UserDefaults = .standard) -> GlobalHotKey {
        let keyCode = defaults.integer(forKey: globalAppSearchHotKeyKeyCodeKey)
        let modifiers = defaults.integer(forKey: globalAppSearchHotKeyModifierFlagsKey)
        let hotKey = GlobalHotKey(keyCode: UInt32(max(0, keyCode)), modifiers: UInt32(max(0, modifiers)))

        return hotKey.isValid ? hotKey : .defaultAppSearch
    }

    static func saveGlobalAppSearchHotKey(
        enabled: Bool,
        hotKey: GlobalHotKey,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: globalAppSearchHotKeyEnabledKey)
        defaults.set(true, forKey: globalAppSearchHotKeyConfirmationResolvedKey)
        defaults.set(Int(hotKey.keyCode), forKey: globalAppSearchHotKeyKeyCodeKey)
        defaults.set(Int(hotKey.modifiers), forKey: globalAppSearchHotKeyModifierFlagsKey)
        defaults.synchronize()
        DiagnosticLogger.shared.log(
            category: "settings",
            event: "settings.globalAppSearchHotKeyChanged",
            fields: [
                "enabled": .publicBool(enabled),
                "keyCode": .publicInt(Int(hotKey.keyCode)),
                "modifiers": .publicInt(Int(hotKey.modifiers))
            ]
        )
        postSettingsDidChangeNotification(globalAppSearchHotKeyDidChangeNotification, defaults: defaults)
    }

    static func menuBarIconEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: menuBarIconEnabledKey)
    }

    static func saveMenuBarIconEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        guard menuBarIconEnabled(defaults: defaults) != enabled else { return }

        defaults.set(enabled, forKey: menuBarIconEnabledKey)
        defaults.synchronize()
        DiagnosticLogger.shared.log(
            category: "settings",
            event: "settings.menuBarIconChanged",
            fields: [
                "enabled": .publicBool(enabled)
            ]
        )
        postSettingsDidChangeNotification(menuBarIconDidChangeNotification, defaults: defaults)
    }

    static func statusFooterMode(defaults: UserDefaults = .standard) -> AppStatusFooterMode {
        guard
            let rawValue = defaults.string(forKey: statusFooterModeKey),
            let mode = AppStatusFooterMode(rawValue: rawValue)
        else {
            return .simple
        }

        return mode
    }

    static func saveStatusFooterMode(_ mode: AppStatusFooterMode, defaults: UserDefaults = .standard) {
        guard statusFooterMode(defaults: defaults) != mode else { return }

        defaults.set(mode.rawValue, forKey: statusFooterModeKey)
        defaults.synchronize()
        DiagnosticLogger.shared.log(
            category: "settings",
            event: "settings.statusFooterModeChanged",
            fields: [
                "mode": .publicString(mode.rawValue)
            ]
        )
        postSettingsDidChangeNotification(statusFooterModeDidChangeNotification, defaults: defaults)
    }

    static func diagnosticLogLevel(defaults: UserDefaults = .standard) -> DiagnosticLogLevel {
        guard
            let rawValue = defaults.string(forKey: diagnosticLogLevelKey),
            let level = DiagnosticLogLevel(rawValue: rawValue)
        else {
            return .info
        }

        return level
    }

    static func saveDiagnosticLogLevel(
        _ level: DiagnosticLogLevel,
        defaults: UserDefaults = .standard
    ) {
        guard diagnosticLogLevel(defaults: defaults) != level else { return }

        defaults.set(level.rawValue, forKey: diagnosticLogLevelKey)
        defaults.synchronize()
        DiagnosticLogger.shared.setMinimumLevel(level)
        DiagnosticLogger.shared.log(
            category: "settings",
            event: "settings.diagnosticLogLevelChanged",
            fields: [
                "level": .publicString(level.rawValue)
            ]
        )
        postSettingsDidChangeNotification(diagnosticLogLevelDidChangeNotification, defaults: defaults)
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
        DiagnosticLogger.shared.log(
            category: "settings",
            event: "settings.indexedRootsChanged",
            fields: [
                "rootCount": .publicInt(paths.count)
            ],
            diagnosticFields: [
                "roots": .pathArray(paths)
            ]
        )
        postSettingsDidChangeNotification(indexedRootsDidChangeNotification, defaults: defaults)
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

    static func appSearchRoots(defaults: UserDefaults = .standard) -> [URL] {
        guard appSearchRootsConfigured(defaults: defaults) else {
            return suggestedDefaultAppSearchRoots()
        }

        return uniqueRoots(savedAppSearchRootURLs(defaults: defaults))
    }

    static func appSearchRootsConfigured(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: appSearchRootsInitializedKey)
            || !(defaults.array(forKey: appSearchRootsKey) as? [String] ?? []).isEmpty
    }

    static func saveAppSearchRoots(_ roots: [URL], defaults: UserDefaults = .standard) {
        let paths = uniqueRoots(roots).map(\.path)
        defaults.set(paths, forKey: appSearchRootsKey)
        defaults.set(true, forKey: appSearchRootsInitializedKey)
        defaults.synchronize()
        DiagnosticLogger.shared.log(
            category: "settings",
            event: "settings.appSearchRootsChanged",
            fields: [
                "rootCount": .publicInt(paths.count)
            ],
            diagnosticFields: [
                "roots": .pathArray(paths)
            ]
        )
        postSettingsDidChangeNotification(appSearchRootsDidChangeNotification, defaults: defaults)
    }

    static func resetAppSearchRoots(defaults: UserDefaults = .standard) {
        saveAppSearchRoots(suggestedDefaultAppSearchRoots(), defaults: defaults)
    }

    static func exclusionPatterns(defaults: UserDefaults = .standard) -> [String] {
        defaults.array(forKey: exclusionPatternsKey) as? [String] ?? FileExclusionRules.defaultPatterns
    }

    static func saveExclusionPatterns(_ patterns: [String], defaults: UserDefaults = .standard) {
        defaults.set(patterns, forKey: exclusionPatternsKey)
        defaults.synchronize()
        DiagnosticLogger.shared.log(
            category: "settings",
            event: "settings.exclusionPatternsChanged",
            fields: [
                "patternCount": .publicInt(patterns.count)
            ],
            diagnosticFields: [
                "patterns": .privateString(patterns.joined(separator: "\n"))
            ]
        )
        postSettingsDidChangeNotification(exclusionPatternsDidChangeNotification, defaults: defaults)
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

    static func defaultAppSearchRoots() -> [URL] {
        suggestedDefaultAppSearchRoots()
    }

    static func suggestedDefaultIndexedRoots() -> [URL] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Developer", isDirectory: true)
        ]

        return candidates.filter { fileManager.fileExists(atPath: $0.path) }
    }

    static func suggestedDefaultAppSearchRoots() -> [URL] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true)
        ]

        return uniqueRoots(candidates.filter { fileManager.fileExists(atPath: $0.path) })
    }

    private static func savedIndexedRootURLs(defaults: UserDefaults) -> [URL] {
        (defaults.array(forKey: indexedRootsKey) as? [String] ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static func savedAppSearchRootURLs(defaults: UserDefaults) -> [URL] {
        (defaults.array(forKey: appSearchRootsKey) as? [String] ?? [])
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
        if currentVersion < 10 {
            let retiredPatterns = Set(retiredSearchableUnrealDefaultExclusionPatterns)
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
            additions.append("Engine/DerivedDataCache/")
            additions.append("Engine/Intermediate/")
            additions.append("Engine/Saved/")
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
        if version < 9 {
            additions.append(".git/*")
            additions.append("!.git/config")
            additions.append("!.git/HEAD")
            additions.append("!.git/description")
            additions.append("!.git/hooks/**")
            additions.append("!.git/info/**")
        }
        return additions
    }
}
