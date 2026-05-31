import AppKit
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
    static let exclusionPatternsKey = "ATTExclusionPatterns"
    static let exclusionDefaultsVersionKey = "ATTExclusionDefaultsVersion"
    static let globalSearchHotKeyDidChangeNotification = Notification.Name("com.allthethings.settings.globalSearchHotKeyDidChange")
    static let menuBarIconDidChangeNotification = Notification.Name("com.allthethings.settings.menuBarIconDidChange")
    static let themePreferenceDidChangeNotification = Notification.Name("com.allthethings.settings.themePreferenceDidChange")
    static let appFontDidChangeNotification = Notification.Name("com.allthethings.settings.appFontDidChange")
    static let matchColorsDidChangeNotification = Notification.Name("com.allthethings.settings.matchColorsDidChange")
    static let indexedRootsDidChangeNotification = Notification.Name("com.allthethings.settings.indexedRootsDidChange")
    static let exclusionPatternsDidChangeNotification = Notification.Name("com.allthethings.settings.exclusionPatternsDidChange")

    static let defaultAppFontSize: CGFloat = 12
    static let appFontSizeRange: ClosedRange<CGFloat> = 10...18

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

    static func appFontFamilyName(defaults: UserDefaults = .standard) -> String? {
        guard
            let familyName = defaults.string(forKey: appFontFamilyNameKey),
            !familyName.isEmpty,
            NSFontManager.shared.availableFontFamilies.contains(familyName)
        else {
            return nil
        }

        return familyName
    }

    static func appFontSize(defaults: UserDefaults = .standard) -> CGFloat {
        let value = defaults.object(forKey: appFontSizeKey) as? NSNumber
        return clampedFontSize(CGFloat(value?.doubleValue ?? Double(defaultAppFontSize)))
    }

    static func appFont(
        defaults: UserDefaults = .standard,
        sizeDelta: CGFloat = 0,
        weight: NSFont.Weight = .regular
    ) -> NSFont {
        let size = max(8, appFontSize(defaults: defaults) + sizeDelta)

        guard let familyName = appFontFamilyName(defaults: defaults) else {
            return .systemFont(ofSize: size, weight: weight)
        }

        return NSFontManager.shared.font(
            withFamily: familyName,
            traits: [],
            weight: fontManagerWeight(for: weight),
            size: size
        ) ?? NSFont(name: familyName, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    static func saveAppFontFamilyName(_ familyName: String?, defaults: UserDefaults = .standard) {
        let normalizedFamilyName = familyName.flatMap { $0.isEmpty ? nil : $0 }
        guard appFontFamilyName(defaults: defaults) != normalizedFamilyName else { return }

        defaults.set(normalizedFamilyName ?? "", forKey: appFontFamilyNameKey)
        defaults.synchronize()
        NotificationCenter.default.post(name: appFontDidChangeNotification, object: defaults)
    }

    static func saveAppFontSize(_ fontSize: CGFloat, defaults: UserDefaults = .standard) {
        let normalizedSize = clampedFontSize(fontSize)
        guard appFontSize(defaults: defaults) != normalizedSize else { return }

        defaults.set(Double(normalizedSize), forKey: appFontSizeKey)
        defaults.synchronize()
        NotificationCenter.default.post(name: appFontDidChangeNotification, object: defaults)
    }

    static func resetAppFont(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: appFontFamilyNameKey)
        defaults.removeObject(forKey: appFontSizeKey)
        defaults.synchronize()
        NotificationCenter.default.post(name: appFontDidChangeNotification, object: defaults)
    }

    static func matchColor(
        for matchClass: MatchClass,
        isDark: Bool,
        defaults: UserDefaults = .standard
    ) -> NSColor {
        let hexes = matchColorHexes(defaults: defaults, isDark: isDark)
        let key = matchColorKey(for: matchClass)
        let defaultHex = defaultMatchColorHexes(isDark: isDark)[key]

        guard
            let hex = hexes[key] ?? defaultHex,
            let color = color(fromHexString: hex)
        else {
            return defaultMatchColor(for: matchClass, isDark: isDark)
        }

        return color
    }

    static func saveMatchColor(
        _ color: NSColor,
        for matchClass: MatchClass,
        isDark: Bool,
        defaults: UserDefaults = .standard
    ) {
        guard let hex = hexString(for: color) else { return }

        let storageKey = matchColorStorageKey(isDark: isDark)
        let key = matchColorKey(for: matchClass)
        var hexes = matchColorHexes(defaults: defaults, isDark: isDark)
        guard hexes[key] != hex else { return }

        hexes[key] = hex
        defaults.set(hexes, forKey: storageKey)
        defaults.synchronize()
        NotificationCenter.default.post(name: matchColorsDidChangeNotification, object: defaults)
    }

    static func resetMatchColors(isDark: Bool, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: matchColorStorageKey(isDark: isDark))
        defaults.synchronize()
        NotificationCenter.default.post(name: matchColorsDidChangeNotification, object: defaults)
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

    private static func matchColorHexes(defaults: UserDefaults, isDark: Bool) -> [String: String] {
        let defaultsHexes = defaultMatchColorHexes(isDark: isDark)
        let savedHexes = defaults.dictionary(forKey: matchColorStorageKey(isDark: isDark)) as? [String: String] ?? [:]
        return defaultsHexes.merging(savedHexes) { _, saved in saved }
    }

    private static func clampedFontSize(_ fontSize: CGFloat) -> CGFloat {
        max(appFontSizeRange.lowerBound, min(appFontSizeRange.upperBound, fontSize.rounded()))
    }

    private static func fontManagerWeight(for weight: NSFont.Weight) -> Int {
        switch weight.rawValue {
        case ..<NSFont.Weight.regular.rawValue:
            return 4
        case ..<NSFont.Weight.medium.rawValue:
            return 5
        case ..<NSFont.Weight.semibold.rawValue:
            return 6
        case ..<NSFont.Weight.bold.rawValue:
            return 8
        default:
            return 9
        }
    }

    private static func matchColorStorageKey(isDark: Bool) -> String {
        isDark ? darkMatchColorsKey : lightMatchColorsKey
    }

    private static func defaultMatchColorHexes(isDark: Bool) -> [String: String] {
        Dictionary(uniqueKeysWithValues: MatchClass.allCases.map { matchClass in
            (matchColorKey(for: matchClass), hexString(for: defaultMatchColor(for: matchClass, isDark: isDark)) ?? "#666666")
        })
    }

    private static func defaultMatchColor(for matchClass: MatchClass, isDark: Bool) -> NSColor {
        if isDark {
            switch matchClass {
            case .exact:
                return NSColor(calibratedRed: 0.78, green: 0.48, blue: 1.0, alpha: 1)
            case .prefix:
                return NSColor(calibratedRed: 0.36, green: 0.64, blue: 1.0, alpha: 1)
            case .substring:
                return NSColor(calibratedRed: 0.98, green: 0.78, blue: 0.22, alpha: 1)
            case .near:
                return NSColor(calibratedRed: 1.0, green: 0.60, blue: 0.28, alpha: 1)
            case .weakPath:
                return NSColor(calibratedRed: 0.74, green: 0.62, blue: 1.0, alpha: 1)
            case .metadata:
                return NSColor(calibratedWhite: 0.82, alpha: 1)
            }
        }

        switch matchClass {
        case .exact:
            return NSColor(calibratedRed: 0.57, green: 0.24, blue: 0.78, alpha: 1)
        case .prefix:
            return NSColor(calibratedRed: 0.05, green: 0.38, blue: 0.82, alpha: 1)
        case .substring:
            return NSColor(calibratedRed: 0.72, green: 0.49, blue: 0.00, alpha: 1)
        case .near:
            return NSColor(calibratedRed: 0.78, green: 0.32, blue: 0.00, alpha: 1)
        case .weakPath:
            return NSColor(calibratedRed: 0.38, green: 0.32, blue: 0.78, alpha: 1)
        case .metadata:
            return NSColor(calibratedWhite: 0.40, alpha: 1)
        }
    }

    private static func matchColorKey(for matchClass: MatchClass) -> String {
        switch matchClass {
        case .exact: "exact"
        case .prefix: "prefix"
        case .substring: "substring"
        case .near: "near"
        case .weakPath: "weakPath"
        case .metadata: "metadata"
        }
    }

    private static func hexString(for color: NSColor) -> String? {
        guard let rgbColor = color.usingColorSpace(NSColorSpace.sRGB) else { return nil }

        let red = max(0, min(255, Int((rgbColor.redComponent * 255).rounded())))
        let green = max(0, min(255, Int((rgbColor.greenComponent * 255).rounded())))
        let blue = max(0, min(255, Int((rgbColor.blueComponent * 255).rounded())))

        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    private static func color(fromHexString hexString: String) -> NSColor? {
        var value = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }

        guard value.count == 6, let intValue = Int(value, radix: 16) else { return nil }

        return NSColor(
            srgbRed: CGFloat((intValue >> 16) & 0xFF) / 255,
            green: CGFloat((intValue >> 8) & 0xFF) / 255,
            blue: CGFloat(intValue & 0xFF) / 255,
            alpha: 1
        )
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
        guard version < 2 else { return [] }
        return FileExclusionRules.defaultPatterns.filter { !versionOneDefaultExclusionPatterns.contains($0) }
    }
}
