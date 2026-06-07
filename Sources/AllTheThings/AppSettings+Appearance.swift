import ATTCore
import AppKit
import Foundation

extension AppSettings {
    static let defaultAppFontSize: CGFloat = 12
    static let appFontSizeRange: ClosedRange<CGFloat> = 10...18

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

    static func defaultMatchColorHexes(isDark: Bool) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: MatchClass.allCases.map { matchClass in
                (
                    matchColorKey(for: matchClass),
                    hexString(for: defaultMatchColor(for: matchClass, isDark: isDark)) ?? "#666666"
                )
            })
    }

    private static func matchColorHexes(defaults: UserDefaults, isDark: Bool) -> [String: String] {
        let defaultsHexes = defaultMatchColorHexes(isDark: isDark)
        let savedHexes =
            defaults.dictionary(forKey: matchColorStorageKey(isDark: isDark)) as? [String: String]
            ?? [:]
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

    private static func defaultMatchColor(for matchClass: MatchClass, isDark: Bool) -> NSColor {
        if isDark {
            switch matchClass {
            case .alias:
                return NSColor(calibratedRed: 0.30, green: 0.84, blue: 0.72, alpha: 1)
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
        case .alias:
            return NSColor(calibratedRed: 0.00, green: 0.50, blue: 0.42, alpha: 1)
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
        case .alias: "alias"
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
}
