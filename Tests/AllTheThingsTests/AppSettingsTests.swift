@testable import AllTheThings
import AppKit
import ATTCore
import Carbon.HIToolbox
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
        #expect(!AppSettings.indexingSetupCompleted(defaults: defaults))
        #expect(AppSettings.indexedRoots(defaults: defaults).isEmpty)
        #expect(!AppSettings.indexedRootsConfigured(defaults: defaults))
        #expect(!AppSettings.indexingSetupCompleted(defaults: defaults))
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
        #expect(AppSettings.indexingSetupCompleted(defaults: defaults))
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
        #expect(AppSettings.indexingSetupCompleted(defaults: defaults))
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
        #expect(!AppSettings.indexingSetupCompleted(defaults: defaults))
        #expect(AppSettings.indexedRoots(defaults: defaults) == AppSettings.suggestedDefaultIndexedRoots())
    }

    @Test("settings change notifications are delivered on the main thread")
    func settingsChangeNotificationsAreDeliveredOnMainThread() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let probe = NotificationThreadProbe()
        let notificationReceived = DispatchSemaphore(value: 0)
        let observer = NotificationCenter.default.addObserver(
            forName: AppSettings.indexedRootsDidChangeNotification,
            object: defaults,
            queue: nil
        ) { _ in
            probe.record(Thread.isMainThread)
            notificationReceived.signal()
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        let defaultsBox = UserDefaultsThreadBox(defaults)
        DispatchQueue.global(qos: .userInitiated).async {
            AppSettings.saveIndexedRoots(
                [URL(fileURLWithPath: "/tmp/AllTheThingsThreadedSettings", isDirectory: true)],
                defaults: defaultsBox.defaults
            )
        }

        #expect(notificationReceived.wait(timeout: .now() + 2) == .success)
        #expect(probe.receivedOnMainThread)
    }

    @Test("default indexed roots exclude Applications")
    func defaultIndexedRootsExcludeApplications() {
        let paths = AppSettings.suggestedDefaultIndexedRoots().map(\.standardizedFileURL.path)

        #expect(!paths.contains("/Applications"))
    }

    @Test("legacy default indexed roots move Applications to app search defaults")
    func legacyDefaultIndexedRootsMoveApplicationsToAppSearchDefaults() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let legacyRoots = AppSettings.suggestedDefaultIndexedRoots()
            + [URL(fileURLWithPath: "/Applications", isDirectory: true)]
        defaults.set(legacyRoots.map(\.standardizedFileURL.path), forKey: AppSettings.indexedRootsKey)
        defaults.set(true, forKey: AppSettings.indexedRootsInitializedKey)

        AppSettings.registerDefaults(defaults)

        let indexedPaths = AppSettings.indexedRoots(defaults: defaults).map(\.standardizedFileURL.path)
        let appSearchPaths = AppSettings.appSearchRoots(defaults: defaults).map(\.standardizedFileURL.path)
        #expect(indexedPaths == AppSettings.suggestedDefaultIndexedRoots().map(\.standardizedFileURL.path))
        #expect(!indexedPaths.contains("/Applications"))
        #expect(appSearchPaths.contains("/Applications"))
    }

    @Test("app search roots default save and reset separately from indexed roots")
    func appSearchRootsDefaultSaveAndResetSeparatelyFromIndexedRoots() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        AppSettings.registerDefaults(defaults)
        #expect(!AppSettings.appSearchRootsConfigured(defaults: defaults))
        #expect(AppSettings.appSearchRoots(defaults: defaults) == AppSettings.suggestedDefaultAppSearchRoots())
        #expect(!AppSettings.appSearchRootsConfigured(defaults: defaults))
        #expect(defaults.object(forKey: AppSettings.appSearchRootsKey) == nil)

        let root = URL(fileURLWithPath: "/tmp/AllTheThingsApps", isDirectory: true)
        AppSettings.saveAppSearchRoots([root], defaults: defaults)

        #expect(AppSettings.appSearchRootsConfigured(defaults: defaults))
        #expect(AppSettings.appSearchRoots(defaults: defaults) == [root.standardizedFileURL])
        #expect(!AppSettings.indexedRootsConfigured(defaults: defaults))

        AppSettings.resetAppSearchRoots(defaults: defaults)
        #expect(AppSettings.appSearchRootsConfigured(defaults: defaults))
        #expect(AppSettings.appSearchRoots(defaults: defaults) == AppSettings.suggestedDefaultAppSearchRoots())
    }

    @Test("global app search hotkey defaults to shift option space and requires confirmation")
    func globalAppSearchHotKeyDefaultsToShiftOptionSpaceAndRequiresConfirmation() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        AppSettings.registerDefaults(defaults)

        #expect(AppSettings.globalAppSearchHotKeyEnabled(defaults: defaults))
        #expect(AppSettings.globalAppSearchHotKeyNeedsConfirmation(defaults: defaults))
        #expect(AppSettings.globalAppSearchHotKey(defaults: defaults) == GlobalHotKey.defaultAppSearch)
        #expect(GlobalHotKey.defaultAppSearch.keyCode == UInt32(kVK_Space))
        #expect(GlobalHotKey.defaultAppSearch.modifiers == UInt32(shiftKey | optionKey))
        #expect(GlobalHotKey.defaultAppSearch.displayString == "⇧⌥Space")
    }

    @Test("saving global app search hotkey resolves confirmation")
    func savingGlobalAppSearchHotKeyResolvesConfirmation() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        AppSettings.registerDefaults(defaults)
        let hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | optionKey))

        AppSettings.saveGlobalAppSearchHotKey(enabled: false, hotKey: hotKey, defaults: defaults)

        #expect(!AppSettings.globalAppSearchHotKeyEnabled(defaults: defaults))
        #expect(!AppSettings.globalAppSearchHotKeyNeedsConfirmation(defaults: defaults))
        #expect(AppSettings.globalAppSearchHotKey(defaults: defaults) == hotKey)
    }

    @Test("status footer defaults to simple and can be detailed")
    func statusFooterDefaultsToSimpleAndCanBeDetailed() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        AppSettings.registerDefaults(defaults)

        #expect(AppSettings.statusFooterMode(defaults: defaults) == .simple)

        AppSettings.saveStatusFooterMode(.detailed, defaults: defaults)

        #expect(AppSettings.statusFooterMode(defaults: defaults) == .detailed)
        #expect(defaults.string(forKey: AppSettings.statusFooterModeKey) == AppStatusFooterMode.detailed.rawValue)
    }

    @Test("hotkey controller ignores events registered to another controller")
    func hotKeyControllerIgnoresEventsRegisteredToAnotherController() {
        let searchHotKeyID = EventHotKeyID(signature: OSType(0x41545448), id: 1)
        let appSearchHotKeyID = EventHotKeyID(signature: OSType(0x41545448), id: 2)
        let foreignHotKeyID = EventHotKeyID(signature: OSType(0), id: 1)

        #expect(GlobalHotKeyController.dispatchStatus(for: searchHotKeyID, controllerHotKeyIDValue: 1) == noErr)
        #expect(GlobalHotKeyController.dispatchStatus(for: appSearchHotKeyID, controllerHotKeyIDValue: 1) == GlobalHotKeyController.eventNotHandledStatus)
        #expect(GlobalHotKeyController.dispatchStatus(for: foreignHotKeyID, controllerHotKeyIDValue: 1) == GlobalHotKeyController.eventNotHandledStatus)
    }

    @Test("setup folder edits stay pending until indexing starts")
    func setupFolderEditsStayPendingUntilIndexingStarts() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        AppSettings.initializeIndexedRootsWithDefaultsIfNeeded(defaults: defaults)
        let root = URL(fileURLWithPath: "/tmp/AllTheThingsTests", isDirectory: true)
        AppSettings.saveIndexedRoots([root], defaults: defaults)

        #expect(AppSettings.indexedRootsConfigured(defaults: defaults))
        #expect(!AppSettings.indexingSetupCompleted(defaults: defaults))
        #expect(AppSettings.indexedRoots(defaults: defaults) == [root.standardizedFileURL])
    }

    @Test("marking indexing setup complete allows configured roots to index")
    func markingIndexingSetupCompleteAllowsConfiguredRootsToIndex() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        AppSettings.initializeIndexedRootsWithDefaultsIfNeeded(defaults: defaults)
        AppSettings.markIndexingSetupCompleted(defaults: defaults)

        #expect(AppSettings.indexingSetupCompleted(defaults: defaults))
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

    @Test("exclusion defaults migration adds generated SDK build and buck noise")
    func exclusionDefaultsMigrationAddsGeneratedSDKBuildAndBuckNoise() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(3, forKey: AppSettings.exclusionDefaultsVersionKey)
        defaults.set([
            ".git/objects/",
            "node_modules/",
            "DerivedData/",
            "Engine/Content/",
            "Engine/Source/ThirdParty/",
            "Engine/Source/Runtime/Engine/Private/",
            "thirdparty/",
            "third_party/",
            "vendor/"
        ], forKey: AppSettings.exclusionPatternsKey)

        AppSettings.registerDefaults(defaults)

        let patterns = AppSettings.exclusionPatterns(defaults: defaults)
        #expect(patterns.contains("Engine/Binaries/ThirdParty/DotNet/"))
        #expect(patterns.contains("Engine/Binaries/ThirdParty/Python3/"))
        #expect(patterns.contains(".build/**/index/store/"))
        #expect(patterns.contains("buck-out/"))
        #expect(patterns.contains("bazel-out/"))
        #expect(patterns.contains(".buckd/"))
        #expect(!patterns.contains("Engine/Content/"))
        #expect(!patterns.contains("Engine/Source/ThirdParty/"))
        #expect(!patterns.contains("Engine/Source/Runtime/Engine/Private/"))
        #expect(patterns.contains("Engine/DerivedDataCache/"))
        #expect(patterns.contains("Engine/Intermediate/"))
        #expect(patterns.contains("Engine/Saved/"))
        #expect(patterns.contains("CMakeFiles/"))
        #expect(patterns.contains("Testing/Temporary/"))
        #expect(patterns.contains("build/.cmake/api/"))
        #expect(patterns.contains("build/_deps/"))
        #expect(patterns.contains("build/**/_deps/"))
        #expect(patterns.contains("build/**/*.tmp*"))
        #expect(patterns.contains(".build/debug/"))
        #expect(patterns.contains(".build/release/"))
        #expect(patterns.contains(".build/*/debug/"))
        #expect(patterns.contains(".build/*/release/"))
        #expect(patterns.contains(".build/*/index/"))
        #expect(patterns.contains(".build/*/ModuleCache/"))
        #expect(patterns.contains(".build/plugins/"))
        #expect(patterns.contains(".build/artifacts/"))
        #expect(patterns.contains("*.o"))
        #expect(patterns.contains("*.pyc"))
        #expect(patterns.contains("*.pyo"))
        #expect(patterns.contains("*.dSYM/"))
        #expect(patterns.contains("*.gcda"))
        #expect(patterns.contains("*.gcno"))
        #expect(patterns.contains("*.profraw"))
        #expect(patterns.contains("*.profdata"))
        #expect(!patterns.contains("thirdparty/"))
        #expect(!patterns.contains("third_party/"))
        #expect(!patterns.contains("vendor/"))
        #expect(patterns.contains(".venv/"))
        #expect(patterns.contains("*.app/Contents/_CodeSignature/"))
        #expect(patterns.contains("Xcode.app/Contents/Developer/Platforms/"))
        #expect(patterns.contains("Xcode.app/Contents/Developer/Toolchains/"))
        #expect(patterns.contains(".git/*"))
        #expect(patterns.contains("!.git/config"))
        #expect(patterns.contains("!.git/HEAD"))
        #expect(patterns.contains("!.git/description"))
        #expect(patterns.contains("!.git/hooks/**"))
        #expect(patterns.contains("!.git/info/**"))
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

    @Test("diagnostic log level defaults to standard info and saves diagnostic")
    func diagnosticLogLevelDefaultsToStandardInfoAndSavesDiagnostic() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            DiagnosticLogger.shared.setMinimumLevel(.info)
        }

        AppSettings.registerDefaults(defaults)
        #expect(AppSettings.diagnosticLogLevel(defaults: defaults) == .info)

        AppSettings.saveDiagnosticLogLevel(.diagnostic, defaults: defaults)

        #expect(AppSettings.diagnosticLogLevel(defaults: defaults) == .diagnostic)
        #expect(defaults.string(forKey: AppSettings.diagnosticLogLevelKey) == DiagnosticLogLevel.diagnostic.rawValue)
        #expect(DiagnosticLogger.shared.currentMinimumLevel() == .diagnostic)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "AllTheThingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

private final class UserDefaultsThreadBox: @unchecked Sendable {
    let defaults: UserDefaults

    init(_ defaults: UserDefaults) {
        self.defaults = defaults
    }
}

private final class NotificationThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedOnMain = false

    var receivedOnMainThread: Bool {
        lock.withLock {
            receivedOnMain
        }
    }

    func record(_ isMainThread: Bool) {
        lock.withLock {
            receivedOnMain = isMainThread
        }
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
