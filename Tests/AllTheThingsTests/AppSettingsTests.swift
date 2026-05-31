@testable import AllTheThings
import AppKit
import ATTCore
import Foundation
import Testing

@Suite("App settings")
struct AppSettingsTests {
    @Test("reading unconfigured indexed roots does not persist defaults")
    func readingUnconfiguredIndexedRootsDoesNotPersistDefaults() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        AppSettings.registerDefaults(defaults)

        #expect(!AppSettings.indexedRootsConfigured(defaults: defaults))
        #expect(AppSettings.indexedRoots(defaults: defaults).isEmpty)
        #expect(!AppSettings.indexedRootsConfigured(defaults: defaults))
        #expect(defaults.object(forKey: AppSettings.indexedRootsKey) == nil)
        #expect(defaults.object(forKey: AppSettings.indexedRootsInitializedKey) == nil)
    }

    @Test("saving indexed roots marks indexing configured")
    func savingIndexedRootsMarksIndexingConfigured() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let root = URL(fileURLWithPath: "/tmp/AllTheThingsTests", isDirectory: true)
        AppSettings.saveIndexedRoots([root], defaults: defaults)

        #expect(AppSettings.indexedRootsConfigured(defaults: defaults))
        #expect(AppSettings.indexedRoots(defaults: defaults) == [root.standardizedFileURL])
    }

    @Test("empty saved roots still represent an explicit configured state")
    func emptySavedRootsStillRepresentExplicitConfiguredState() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        AppSettings.saveIndexedRoots([], defaults: defaults)

        #expect(AppSettings.indexedRootsConfigured(defaults: defaults))
        #expect(AppSettings.indexedRoots(defaults: defaults).isEmpty)
    }

    @Test("indexed roots can be initialized with defaults for setup")
    func indexedRootsCanBeInitializedWithDefaultsForSetup() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        AppSettings.initializeIndexedRootsWithDefaultsIfNeeded(defaults: defaults)

        #expect(AppSettings.indexedRootsConfigured(defaults: defaults))
        #expect(AppSettings.indexedRoots(defaults: defaults) == AppSettings.suggestedDefaultIndexedRoots())
    }

    @Test("default indexed root initialization preserves configured roots")
    func defaultIndexedRootInitializationPreservesConfiguredRoots() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let root = URL(fileURLWithPath: "/tmp/AllTheThingsTests", isDirectory: true)
        AppSettings.saveIndexedRoots([root], defaults: defaults)
        AppSettings.initializeIndexedRootsWithDefaultsIfNeeded(defaults: defaults)

        #expect(AppSettings.indexedRoots(defaults: defaults) == [root.standardizedFileURL])
    }

    @Test("exclusion defaults migration adds generated SDK and index-store noise")
    func exclusionDefaultsMigrationAddsGeneratedSDKAndIndexStoreNoise() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(3, forKey: AppSettings.exclusionDefaultsVersionKey)
        defaults.set([
            ".git/objects/",
            "node_modules/",
            "DerivedData/"
        ], forKey: AppSettings.exclusionPatternsKey)

        AppSettings.registerDefaults(defaults)

        let patterns = AppSettings.exclusionPatterns(defaults: defaults)
        #expect(patterns.contains("Engine/Binaries/ThirdParty/DotNet/"))
        #expect(patterns.contains("Engine/Binaries/ThirdParty/Python3/"))
        #expect(patterns.contains(".build/**/index/store/"))
        #expect(patterns.contains("Engine/Content/"))
        #expect(patterns.contains("Engine/Source/ThirdParty/"))
        #expect(patterns.contains("Engine/Source/Runtime/Engine/Private/"))
        #expect(patterns.contains("build/.cmake/api/"))
        #expect(patterns.contains("build/_deps/"))
        #expect(patterns.contains("thirdparty/"))
        #expect(patterns.contains("third_party/"))
        #expect(patterns.contains("vendor/"))
        #expect(patterns.contains(".venv/"))
        #expect(patterns.contains("*.app/Contents/_CodeSignature/"))
        #expect(patterns.contains("Xcode.app/Contents/Developer/Platforms/"))
        #expect(patterns.contains("Xcode.app/Contents/Developer/Toolchains/"))
    }

    @Test("match colors can be overridden and reset per appearance")
    func matchColorsCanBeOverriddenAndResetPerAppearance() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        AppSettings.registerDefaults(defaults)
        let defaultLightColor = AppSettings.matchColor(for: .substring, isDark: false, defaults: defaults)
        let defaultDarkColor = AppSettings.matchColor(for: .substring, isDark: true, defaults: defaults)
        let overrideColor = NSColor(calibratedRed: 0.12, green: 0.34, blue: 0.56, alpha: 1)

        AppSettings.saveMatchColor(overrideColor, for: .substring, isDark: false, defaults: defaults)

        #expect(AppSettings.matchColor(for: .substring, isDark: false, defaults: defaults).hexString == overrideColor.hexString)
        #expect(AppSettings.matchColor(for: .substring, isDark: true, defaults: defaults).hexString == defaultDarkColor.hexString)

        AppSettings.resetMatchColors(isDark: false, defaults: defaults)

        #expect(AppSettings.matchColor(for: .substring, isDark: false, defaults: defaults).hexString == defaultLightColor.hexString)
    }

    @Test("app font settings clamp size and reset to defaults")
    func appFontSettingsClampSizeAndResetToDefaults() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        AppSettings.registerDefaults(defaults)
        AppSettings.saveAppFontSize(999, defaults: defaults)

        #expect(AppSettings.appFontSize(defaults: defaults) == AppSettings.appFontSizeRange.upperBound)

        let familyName = try #require(NSFontManager.shared.availableFontFamilies.first)
        AppSettings.saveAppFontFamilyName(familyName, defaults: defaults)
        #expect(AppSettings.appFontFamilyName(defaults: defaults) == familyName)

        AppSettings.resetAppFont(defaults: defaults)

        #expect(AppSettings.appFontFamilyName(defaults: defaults) == nil)
        #expect(AppSettings.appFontSize(defaults: defaults) == AppSettings.defaultAppFontSize)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "AllTheThingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

private extension NSColor {
    var hexString: String? {
        guard let color = usingColorSpace(.sRGB) else { return nil }

        let red = max(0, min(255, Int((color.redComponent * 255).rounded())))
        let green = max(0, min(255, Int((color.greenComponent * 255).rounded())))
        let blue = max(0, min(255, Int((color.blueComponent * 255).rounded())))

        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
