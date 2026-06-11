import AppKit
import ATTCore
import CoreServices

// AppKit invokes these Objective-C delegate hooks during startup; hop to the
// main queue before touching Swift @MainActor AppKit APIs.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSSearchFieldDelegate {
    private static let activationRequestNotification = Notification.Name("com.allthethings.app.activateExistingInstance")
    private static let diagnosticLogMaxTotalBytes: UInt64 = 50 * 1024 * 1024
    private static let diagnosticLogMaxAge: TimeInterval = 30 * 24 * 60 * 60

    private let defaults = UserDefaults.standard
    private lazy var fileIndex = FileIndex(
        loadsSnapshotImmediately: false,
        exclusionPatterns: AppSettings.exclusionPatterns(defaults: defaults)
    )
    private var windowController: SearchWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var insightsWindowController: InsightsWindowController?
    private var aboutWindowController: NSWindowController?
    private var noticesWindowController: NSWindowController?
    private var globalHotKeyController: GlobalHotKeyController?
    private var globalAppSearchHotKeyController: GlobalHotKeyController?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var statusSearchField: NSSearchField?
    private var isStatusSearchMenuTracking = false
    private var didPresentGlobalHotKeyRegistrationError = false
    private var didPresentGlobalAppSearchHotKeyRegistrationError = false

    override init() {
        AppSettings.registerDefaults(defaults)
        super.init()

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleActivationRequest(_:)),
            name: Self.activationRequestNotification,
            object: Bundle.main.bundleIdentifier
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themePreferenceDidChange(_:)),
            name: AppSettings.themePreferenceDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(globalSearchHotKeyDidChange(_:)),
            name: AppSettings.globalSearchHotKeyDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(globalAppSearchHotKeyDidChange(_:)),
            name: AppSettings.globalAppSearchHotKeyDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuBarIconDidChange(_:)),
            name: AppSettings.menuBarIconDidChangeNotification,
            object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            NSApp.setActivationPolicy(.regular)
            AppTheme.applyCurrent()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if let existingInstance = self.existingInstance(), !self.allowsMultipleInstances {
                self.requestActivation(of: existingInstance)
                NSApp.terminate(nil)
                return
            }

            self.finishLaunching()
        }
    }

    @MainActor
    private func finishLaunching() {
        configureDiagnosticLogging()
        configureMainMenu()
        applyMenuBarIconSetting()
        let launchedAsLoginItem = Self.launchedAsLoginItem()
        DiagnosticLogger.shared.log(
            category: "app",
            event: "app.launch",
            fields: [
                "appVersion": .publicString(Self.appVersionString),
                "launchedAsLoginItem": .publicBool(launchedAsLoginItem),
                "processIdentifier": .publicInt(Int(ProcessInfo.processInfo.processIdentifier))
            ]
        )
        fileIndex.recordAppLaunch(appVersion: Self.appVersionString)
        let window = launchedAsLoginItem ? nil : showPrimaryWindow(activate: true)
        configureGlobalHotKeys(presentsErrors: !launchedAsLoginItem)
        if !launchedAsLoginItem {
            ReleaseUpdater.shared.checkAutomaticallyIfNeeded(presentingWindow: window)
        }
    }

    @MainActor
    private func configureDiagnosticLogging() {
        let logsURL = fileIndex.dataDirectoryURL.appendingPathComponent("Logs", isDirectory: true)
        DiagnosticLogger.shared.configure(
            directoryURL: logsURL,
            maxTotalBytes: Self.diagnosticLogMaxTotalBytes,
            maxAge: Self.diagnosticLogMaxAge
        )
        DiagnosticLogger.shared.setMinimumLevel(AppSettings.diagnosticLogLevel(defaults: defaults))
    }

    @discardableResult
    @MainActor
    private func showPrimaryWindow(activate: Bool) -> NSWindow? {
        let controller = primarySearchWindowController()

        controller.showWindow(nil)
        NSApp.unhide(nil)
        controller.window?.deminiaturize(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.orderFrontRegardless()
        if activate {
            NSApp.activate()
        }

        return controller.window
    }

    @MainActor
    private func showPrimaryWindowForStatusSearchPreview() -> NSWindow? {
        let controller = primarySearchWindowController()
        let shouldShowWindow = controller.window?.isVisible != true

        if shouldShowWindow {
            controller.suppressNextSearchFieldFocusOnAppear()
            NSApp.unhide(nil)
            controller.window?.deminiaturize(nil)
            controller.window?.orderFrontRegardless()
        }

        return controller.window
    }

    @MainActor
    private func primarySearchWindowController() -> SearchWindowController {
        let controller: SearchWindowController
        if let existingController = windowController {
            controller = existingController
        } else {
            let newController = SearchWindowController(index: fileIndex)
            windowController = newController
            controller = newController
        }

        return controller
    }

    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventClass == AEEventClass(kCoreEventClass)
            && event.eventID == AEEventID(kAEOpenApplication)
            && event.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
    }

    private static var appVersionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (version?, build?) where !version.isEmpty && !build.isEmpty:
            return "\(version) (\(build))"
        case let (version?, _) where !version.isEmpty:
            return version
        case let (_, build?) where !build.isEmpty:
            return build
        default:
            return "unknown"
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        performSelector(onMainThread: #selector(showPrimaryWindowFromActivationRequest), with: nil, waitUntilDone: false)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        DiagnosticLogger.shared.log(category: "app", event: "app.terminate")
        DiagnosticLogger.shared.flush()
    }

    private var allowsMultipleInstances: Bool {
        defaults.bool(forKey: AppSettings.allowMultipleInstancesKey)
    }

    private func existingInstance() -> NSRunningApplication? {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return nil }
        let currentPID = ProcessInfo.processInfo.processIdentifier

        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { application in
                application.processIdentifier != currentPID && !application.isTerminated
            }
    }

    private func requestActivation(of application: NSRunningApplication) {
        DistributedNotificationCenter.default().postNotificationName(
            Self.activationRequestNotification,
            object: Bundle.main.bundleIdentifier,
            userInfo: ["senderPID": ProcessInfo.processInfo.processIdentifier],
            deliverImmediately: true
        )
        application.activate(options: [.activateAllWindows])
    }

    @objc private func handleActivationRequest(_ notification: Notification) {
        let senderPID = notification.userInfo?["senderPID"] as? Int32
        guard senderPID != ProcessInfo.processInfo.processIdentifier else { return }

        performSelector(onMainThread: #selector(showPrimaryWindowFromActivationRequest), with: nil, waitUntilDone: false)
    }

    @objc @MainActor private func showPrimaryWindowFromActivationRequest() {
        _ = showPrimaryWindow(activate: true)
        windowController?.focusSearchField(selectText: true)
    }

    @MainActor
    func saveGlobalSearchHotKey(enabled: Bool, hotKey: GlobalHotKey) throws {
        try globalHotKeyController?.configure(isEnabled: enabled, hotKey: hotKey)
        AppSettings.saveGlobalSearchHotKey(enabled: enabled, hotKey: hotKey, defaults: defaults)
    }

    @MainActor
    func saveGlobalAppSearchHotKey(enabled: Bool, hotKey: GlobalHotKey) throws {
        try globalAppSearchHotKeyController?.configure(isEnabled: enabled, hotKey: hotKey)
        AppSettings.saveGlobalAppSearchHotKey(enabled: enabled, hotKey: hotKey, defaults: defaults)
    }

    @MainActor
    private func configureGlobalHotKeys(presentsErrors: Bool = false) {
        globalHotKeyController = GlobalHotKeyController(hotKeyIDValue: 1) { [weak self] in
            Task { @MainActor in
                self?.focusSearchFromHotKey()
            }
        }
        globalAppSearchHotKeyController = GlobalHotKeyController(hotKeyIDValue: 2) { [weak self] in
            Task { @MainActor in
                self?.focusAppSearchFromHotKey()
            }
        }

        applyGlobalHotKeySettings(presentsErrors: presentsErrors)
        applyGlobalAppSearchHotKeySettings(presentsErrors: presentsErrors)
    }

    @MainActor
    private func applyGlobalHotKeySettings(presentsErrors: Bool = false) {
        if AppSettings.globalSearchHotKeyNeedsConfirmation(defaults: defaults) {
            return
        }

        do {
            try globalHotKeyController?.configure(
                isEnabled: AppSettings.globalSearchHotKeyEnabled(defaults: defaults),
                hotKey: AppSettings.globalSearchHotKey(defaults: defaults)
            )
        } catch {
            if presentsErrors {
                presentGlobalHotKeyRegistrationError(error)
            } else {
                NSLog("AllTheThings could not register global search hotkey: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func applyGlobalAppSearchHotKeySettings(presentsErrors: Bool = false) {
        if AppSettings.globalAppSearchHotKeyNeedsConfirmation(defaults: defaults) {
            return
        }

        do {
            try globalAppSearchHotKeyController?.configure(
                isEnabled: AppSettings.globalAppSearchHotKeyEnabled(defaults: defaults),
                hotKey: AppSettings.globalAppSearchHotKey(defaults: defaults)
            )
        } catch {
            if presentsErrors {
                presentGlobalAppSearchHotKeyRegistrationError(error)
            } else {
                NSLog("AllTheThings could not register global app search hotkey: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func presentGlobalHotKeyRegistrationError(_ error: Error) {
        guard !didPresentGlobalHotKeyRegistrationError else { return }
        didPresentGlobalHotKeyRegistrationError = true

        let hotKey = AppSettings.globalSearchHotKey(defaults: defaults)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Global search hotkey conflict"
        alert.informativeText = "\(error.localizedDescription)\n\nAllTheThings did not claim \(hotKey.displayString). Open Settings to choose a different shortcut or disable the global hotkey."
        alert.addButton(withTitle: "OK")

        if let window = windowController?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @MainActor
    private func presentGlobalAppSearchHotKeyRegistrationError(_ error: Error) {
        guard !didPresentGlobalAppSearchHotKeyRegistrationError else { return }
        didPresentGlobalAppSearchHotKeyRegistrationError = true

        let hotKey = AppSettings.globalAppSearchHotKey(defaults: defaults)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Global app search hotkey conflict"
        alert.informativeText = "\(error.localizedDescription)\n\nAllTheThings did not claim \(hotKey.displayString). Open Settings to choose a different shortcut or disable the global app search hotkey."
        alert.addButton(withTitle: "OK")

        if let window = windowController?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @MainActor
    private func focusSearchFromHotKey() {
        _ = showPrimaryWindow(activate: true)
        windowController?.focusSearchField(selectText: true)
    }

    @MainActor
    private func focusAppSearchFromHotKey() {
        _ = showPrimaryWindow(activate: true)
        windowController?.focusSearchField(prefill: "app:")
    }

    @objc @MainActor private func toggleLaunchAtLoginFromStatusItem(_ sender: Any?) {
        do {
            try LaunchAtLoginController.setEnabled(!LaunchAtLoginController.isEnabled)
            DiagnosticLogger.shared.log(
                category: "settings",
                event: "settings.launchAtLoginChanged",
                fields: [
                    "enabled": .publicBool(LaunchAtLoginController.isEnabled)
                ]
            )
            if LaunchAtLoginController.requiresApproval {
                presentLaunchAtLoginApprovalAlert()
            }
        } catch {
            DiagnosticLogger.shared.log(
                level: .error,
                category: "settings",
                event: "settings.launchAtLoginChangeFailed",
                fields: [
                    "error": .errorText(error.localizedDescription)
                ]
            )
            presentLaunchAtLoginErrorAlert(error)
        }
    }

    @objc @MainActor private func activateStatusItem(_ sender: NSStatusBarButton) {
        showStatusMenu(relativeTo: sender)
    }

    @objc private func globalSearchHotKeyDidChange(_ notification: Notification) {
        performSelector(onMainThread: #selector(applyGlobalHotKeySettingsFromNotification), with: nil, waitUntilDone: false)
    }

    @objc @MainActor private func applyGlobalHotKeySettingsFromNotification() {
        applyGlobalHotKeySettings()
    }

    @objc private func globalAppSearchHotKeyDidChange(_ notification: Notification) {
        performSelector(onMainThread: #selector(applyGlobalAppSearchHotKeySettingsFromNotification), with: nil, waitUntilDone: false)
    }

    @objc @MainActor private func applyGlobalAppSearchHotKeySettingsFromNotification() {
        applyGlobalAppSearchHotKeySettings()
    }

    @objc private func menuBarIconDidChange(_ notification: Notification) {
        performSelector(onMainThread: #selector(applyMenuBarIconSettingFromNotification), with: nil, waitUntilDone: false)
    }

    @objc @MainActor private func applyMenuBarIconSettingFromNotification() {
        applyMenuBarIconSetting()
    }

    @objc private func themePreferenceDidChange(_ notification: Notification) {
        Task { @MainActor in
            AppTheme.applyCurrent()
        }
    }

    @objc @MainActor private func checkForUpdates(_ sender: Any?) {
        ReleaseUpdater.shared.checkForUpdates(presentingWindow: windowController?.window, userInitiated: true)
    }

    @MainActor
    func showSettings(section: SettingsSection? = nil) {
        presentSettingsWindow(section: section)
    }

    @MainActor
    func showInsights() {
        presentInsightsWindow()
    }

    @objc @MainActor private func showSettingsWindow(_ sender: Any?) {
        presentSettingsWindow()
    }

    @objc @MainActor private func showInsightsWindow(_ sender: Any?) {
        presentInsightsWindow()
    }

    @objc @MainActor private func exportAnonymizedDiagnosticLog(_ sender: Any?) {
        presentDiagnosticLogSavePanel(anonymized: true)
    }

    @objc @MainActor private func exportRawDiagnosticLog(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Export raw diagnostic log?"
        alert.informativeText = "Raw diagnostic logs may include search queries, file paths, and action context. They remain local unless you choose to share the exported file."
        alert.addButton(withTitle: "Export Raw Log")
        alert.addButton(withTitle: "Cancel")

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.presentDiagnosticLogSavePanel(anonymized: false)
        }

        if let window = windowController?.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    @objc @MainActor private func clearLocalDiagnosticLogs(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear local diagnostic logs?"
        alert.informativeText = "This deletes the local structured diagnostic logs stored by AllTheThings. Index data, settings, and aggregate diagnostics are not changed."
        alert.addButton(withTitle: "Clear Logs")
        alert.addButton(withTitle: "Cancel")

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try DiagnosticLogger.shared.clearLogs()
                self.presentDiagnosticLogAlert(message: "Diagnostic logs cleared.", informativeText: "Local structured logs have been deleted.")
            } catch {
                self.presentDiagnosticLogAlert(message: "Could not clear diagnostic logs.", informativeText: error.localizedDescription)
            }
        }

        if let window = windowController?.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    @MainActor
    private func presentDiagnosticLogSavePanel(anonymized: Bool) {
        let panel = NSSavePanel()
        panel.title = anonymized ? "Export Anonymized Diagnostic Log" : "Export Raw Diagnostic Log"
        panel.nameFieldStringValue = anonymized
            ? "AllTheThings-DiagnosticLog-Anonymized.jsonl"
            : "AllTheThings-DiagnosticLog-Raw.jsonl"
        panel.canCreateDirectories = true

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.exportDiagnosticLog(anonymized: anonymized, to: url)
        }

        if let window = windowController?.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    @MainActor
    private func exportDiagnosticLog(anonymized: Bool, to url: URL) {
        let kind = anonymized ? "anonymized" : "raw"
        DiagnosticLogger.shared.log(
            category: "diagnosticLog",
            event: "diagnosticLog.exportRequested",
            fields: [
                "exportKind": .publicString(kind)
            ],
            diagnosticFields: [
                "destination": .path(url.path)
            ]
        )

        let index = fileIndex
        let exporter = DiagnosticLogExporter(
            snapshotProvider: {
                index.currentInsightsSnapshot()
            }
        )

        DispatchQueue.global(qos: .utility).async {
            do {
                if anonymized {
                    try exporter.exportAnonymized(to: url)
                } else {
                    try exporter.exportRaw(to: url)
                }

                DiagnosticLogger.shared.log(
                    category: "diagnosticLog",
                    event: "diagnosticLog.exportFinished",
                    fields: [
                        "exportKind": .publicString(kind)
                    ],
                    diagnosticFields: [
                        "destination": .path(url.path)
                    ]
                )

                let informativeText = url.path
                DispatchQueue.main.async {
                    (NSApp.delegate as? AppDelegate)?.presentDiagnosticLogAlert(
                        message: "Diagnostic log exported.",
                        informativeText: informativeText
                    )
                }
            } catch {
                let informativeText = error.localizedDescription
                DiagnosticLogger.shared.log(
                    level: .error,
                    category: "diagnosticLog",
                    event: "diagnosticLog.exportFailed",
                    fields: [
                        "exportKind": .publicString(kind),
                        "destination": .path(url.path),
                        "error": .errorText(error.localizedDescription)
                    ]
                )

                DispatchQueue.main.async {
                    (NSApp.delegate as? AppDelegate)?.presentDiagnosticLogAlert(
                        message: "Could not export diagnostic log.",
                        informativeText: informativeText
                    )
                }
            }
        }
    }

    @MainActor
    private func presentDiagnosticLogAlert(message: String, informativeText: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informativeText
        alert.addButton(withTitle: "OK")

        if let window = windowController?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @MainActor
    private func presentSettingsWindow(section: SettingsSection? = nil) {
        let controller: SettingsWindowController
        if let existingController = settingsWindowController {
            controller = existingController
        } else {
            controller = SettingsWindowController(
                defaults: defaults,
                index: fileIndex,
                reindexHandler: { [weak self] in
                    self?.reindexFromCurrentSettings()
                }
            )
            settingsWindowController = controller
        }

        if let section {
            controller.selectSection(section)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @MainActor
    private func reindexFromCurrentSettings() {
        guard AppSettings.indexingSetupCompleted(defaults: defaults) else { return }
        let roots = AppSettings.indexedRoots(defaults: defaults)
        guard !roots.isEmpty else { return }

        if let windowController {
            windowController.reindexConfiguredRootsFromSettings()
            return
        }

        fileIndex.setPublishesSearchableSnapshotsDuringScan(false)
        fileIndex.updateExclusionPatterns(AppSettings.exclusionPatterns(defaults: defaults))
        fileIndex.replaceRootsAndRebuild(roots, mode: .fresh)
    }

    @MainActor
    private func presentInsightsWindow() {
        let controller: InsightsWindowController
        if let existingController = insightsWindowController {
            controller = existingController
        } else {
            controller = InsightsWindowController(
                index: fileIndex,
                defaults: defaults,
                clearCachedIndexHandler: { [weak self] in
                    guard let self else { return }
                    try self.fileIndex.clearPersistedIndexData()
                    self.reindexFromCurrentSettings()
                }
            )
            insightsWindowController = controller
        }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc @MainActor private func toggleHiddenFiles(_ sender: Any?) {
        let showHiddenFiles = !defaults.bool(forKey: AppSettings.showHiddenFilesKey)
        defaults.set(showHiddenFiles, forKey: AppSettings.showHiddenFilesKey)
        defaults.synchronize()
        DiagnosticLogger.shared.log(
            category: "settings",
            event: "settings.showHiddenFilesChanged",
            fields: [
                "enabled": .publicBool(showHiddenFiles)
            ]
        )
        (sender as? NSMenuItem)?.state = showHiddenFiles ? .on : .off
    }

    @objc @MainActor private func showAboutWindow(_ sender: Any?) {
        let controller: NSWindowController
        if let existingController = aboutWindowController {
            controller = existingController
        } else {
            controller = makeAboutWindowController()
            aboutWindowController = controller
        }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc @MainActor private func openGameCoreTechWebsite(_ sender: Any?) {
        open(urlString: "https://gamecoretech.com/")
    }

    @objc @MainActor private func openGitHubRepository(_ sender: Any?) {
        open(urlString: "https://github.com/MikeMarcin/AllTheThings")
    }

    @objc @MainActor private func showThirdPartyNotices(_ sender: Any?) {
        let controller: NSWindowController
        if let existingController = noticesWindowController {
            controller = existingController
        } else {
            controller = makeThirdPartyNoticesWindowController()
            noticesWindowController = controller
        }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @MainActor
    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(
            title: "About AllTheThings",
            action: #selector(showAboutWindow(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(showSettingsWindow(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        let insightsItem = NSMenuItem(
            title: "Insights...",
            action: #selector(showInsightsWindow(_:)),
            keyEquivalent: "i"
        )
        insightsItem.keyEquivalentModifierMask = [.command, .option]
        insightsItem.target = self
        appMenu.addItem(insightsItem)

        appMenu.addItem(.separator())

        let checkUpdatesItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkUpdatesItem.target = self
        appMenu.addItem(checkUpdatesItem)

        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide AllTheThings", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit AllTheThings", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let copyPathItem = NSMenuItem(
            title: "Copy Path",
            action: Selector(("copySelectedPath:")),
            keyEquivalent: "c"
        )
        copyPathItem.keyEquivalentModifierMask = [.command, .option]
        editMenu.addItem(copyPathItem)
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.delegate = self
        let hiddenFilesItem = NSMenuItem(
            title: "Show Hidden Files",
            action: #selector(toggleHiddenFiles(_:)),
            keyEquivalent: "."
        )
        hiddenFilesItem.keyEquivalentModifierMask = [.command, .shift]
        hiddenFilesItem.target = self
        viewMenu.addItem(hiddenFilesItem)
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        let noticesItem = NSMenuItem(
            title: "Third-Party Notices",
            action: #selector(showThirdPartyNotices(_:)),
            keyEquivalent: ""
        )
        noticesItem.target = self
        helpMenu.addItem(noticesItem)

        helpMenu.addItem(.separator())

        let exportAnonymizedLogItem = NSMenuItem(
            title: "Export Anonymized Diagnostic Log...",
            action: #selector(exportAnonymizedDiagnosticLog(_:)),
            keyEquivalent: ""
        )
        exportAnonymizedLogItem.target = self
        helpMenu.addItem(exportAnonymizedLogItem)

        let exportRawLogItem = NSMenuItem(
            title: "Export Raw Diagnostic Log...",
            action: #selector(exportRawDiagnosticLog(_:)),
            keyEquivalent: ""
        )
        exportRawLogItem.target = self
        helpMenu.addItem(exportRawLogItem)

        let clearDiagnosticLogsItem = NSMenuItem(
            title: "Clear Local Diagnostic Logs",
            action: #selector(clearLocalDiagnosticLogs(_:)),
            keyEquivalent: ""
        )
        clearDiagnosticLogsItem.target = self
        helpMenu.addItem(clearDiagnosticLogsItem)
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)

        NSApp.mainMenu = mainMenu
    }

    @MainActor
    private func applyMenuBarIconSetting() {
        if AppSettings.menuBarIconEnabled(defaults: defaults) {
            configureStatusItem()
        } else {
            removeStatusItem()
        }
    }

    @MainActor
    private func configureStatusItem() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.makeStatusIconImage()
            button.imagePosition = .imageOnly
            button.toolTip = "AllTheThings - Click to search."
            button.target = self
            button.action = #selector(activateStatusItem(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let menu = NSMenu(title: "AllTheThings")
        menu.delegate = self
        menu.addItem(makeStatusSearchMenuItem())
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(showSettingsWindow(_:)),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let insightsItem = NSMenuItem(
            title: "Insights...",
            action: #selector(showInsightsWindow(_:)),
            keyEquivalent: ""
        )
        insightsItem.target = self
        menu.addItem(insightsItem)

        menu.addItem(.separator())

        let launchAtLoginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLoginFromStatusItem(_:)),
            keyEquivalent: ""
        )
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit AllTheThings",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        )
        menu.addItem(quitItem)

        statusItem = item
        statusMenu = menu
    }

    @MainActor
    private func removeStatusItem() {
        guard let item = statusItem else {
            statusMenu = nil
            statusSearchField = nil
            return
        }

        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        statusMenu = nil
        statusSearchField = nil
    }

    @MainActor
    private func makeStatusSearchMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 44))
        let searchField = NSSearchField(frame: NSRect(x: 12, y: 8, width: 256, height: 28))
        searchField.placeholderString = "Search"
        searchField.target = self
        searchField.action = #selector(submitStatusSearch(_:))
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 15)
        container.addSubview(searchField)
        item.view = container
        statusSearchField = searchField
        return item
    }

    private static func makeStatusIconImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        // Keep the status glyph tied to the real Nib sprite instead of a hand-drawn approximation.
        if let url = Bundle.main.url(forResource: "NibMenuBarTemplate", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = size
            image.isTemplate = true
            return image
        }

        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let scale = min(rect.width / size.width, rect.height / size.height)
            let xOffset = rect.minX + (rect.width - size.width * scale) / 2
            let yOffset = rect.minY + (rect.height - size.height * scale) / 2
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: xOffset + x * scale, y: yOffset + y * scale)
            }
            func fallbackRect(_ x: CGFloat, _ y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
                CGRect(
                    x: point(x, y).x,
                    y: point(x, y).y,
                    width: width * scale,
                    height: height * scale
                )
            }

            context.setFillColor(NSColor.black.cgColor)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            context.setLineWidth(0.7 * scale)
            context.move(to: point(7.0, 12.8))
            context.addLine(to: point(6.3, 15.2))
            context.move(to: point(11.0, 12.8))
            context.addLine(to: point(11.7, 15.2))
            context.strokePath()

            context.addEllipse(in: fallbackRect(5.6, 15.0, width: 1.4, height: 1.4))
            context.addEllipse(in: fallbackRect(11.0, 15.0, width: 1.4, height: 1.4))
            context.fillPath()

            context.addPath(CGPath(
                roundedRect: fallbackRect(3.2, 3.3, width: 11.6, height: 9.9),
                cornerWidth: 2.1 * scale,
                cornerHeight: 2.1 * scale,
                transform: nil
            ))
            context.fillPath()

            context.saveGState()
            context.setBlendMode(.clear)
            context.addEllipse(in: fallbackRect(6.7, 7.5, width: 0.9, height: 1.6))
            context.addEllipse(in: fallbackRect(10.4, 7.5, width: 0.9, height: 1.6))
            context.fillPath()
            context.restoreGState()

            return true
        }
        image.isTemplate = true
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.action == #selector(toggleHiddenFiles(_:)) {
            item.state = defaults.bool(forKey: AppSettings.showHiddenFilesKey) ? .on : .off
        }

        for item in menu.items where item.action == #selector(toggleLaunchAtLoginFromStatusItem(_:)) {
            item.state = LaunchAtLoginController.isEnabled ? .on : .off
        }
    }

    @MainActor
    private func showStatusMenu(relativeTo button: NSStatusBarButton) {
        guard let menu = statusMenu else { return }
        _ = showPrimaryWindowForStatusSearchPreview()
        menuNeedsUpdate(menu)
        isStatusSearchMenuTracking = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
        isStatusSearchMenuTracking = false
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusMenu, let field = statusSearchField else { return }
        field.stringValue = ""
        scheduleStatusSearchFieldFocus()
    }

    @objc @MainActor private func focusStatusSearchFieldFromMenu() {
        guard let field = statusSearchField, field.window != nil else { return }
        let selectedRange = field.currentEditor()?.selectedRange
            ?? NSRange(location: (field.stringValue as NSString).length, length: 0)
        field.window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = selectedRange
    }

    private func scheduleStatusSearchFieldFocus() {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(focusStatusSearchFieldFromMenu),
            object: nil
        )
        perform(
            #selector(focusStatusSearchFieldFromMenu),
            with: nil,
            afterDelay: 0,
            inModes: [.eventTracking, .default]
        )
    }

    func controlTextDidChange(_ notification: Notification) {
        guard
            let field = notification.object as? NSSearchField,
            field === statusSearchField
        else {
            return
        }

        let query = field.stringValue
        Task { @MainActor in
            self.previewSearchWindowFromStatusSearch(query)
            self.focusStatusSearchFieldFromMenu()
            self.scheduleStatusSearchFieldFocus()
        }
    }

    @objc @MainActor private func submitStatusSearch(_ sender: NSSearchField) {
        let query = sender.stringValue
        if query.isEmpty {
            if Self.isReturnKeyEvent(NSApp.currentEvent) {
                focusSearchFromHotKey()
            } else {
                previewSearchWindowFromStatusSearch(query)
                focusStatusSearchFieldFromMenu()
                scheduleStatusSearchFieldFocus()
            }
        } else {
            openSearchWindowFromStatusSearch(query)
        }
    }

    private static func isReturnKeyEvent(_ event: NSEvent?) -> Bool {
        guard event?.type == .keyDown else { return false }
        return event?.keyCode == 36 || event?.keyCode == 76
    }

    @MainActor
    private func openSearchWindowFromStatusSearch(_ query: String) {
        statusMenu?.cancelTracking()
        statusSearchField?.stringValue = ""
        _ = showPrimaryWindow(activate: true)
        windowController?.focusSearchField(prefill: query)
    }

    @MainActor
    private func previewSearchWindowFromStatusSearch(_ query: String) {
        if !isStatusSearchMenuTracking {
            _ = showPrimaryWindowForStatusSearchPreview()
        }
        windowController?.updateSearchQuery(query)
    }

    @MainActor
    private func presentLaunchAtLoginApprovalAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Approve launch at login"
        alert.informativeText = "macOS needs approval before AllTheThings can start automatically when you sign in."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                LaunchAtLoginController.openSystemSettings()
            }
        }

        if let window = windowController?.window ?? settingsWindowController?.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    @MainActor
    private func presentLaunchAtLoginErrorAlert(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not update launch at login"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")

        if let window = windowController?.window ?? settingsWindowController?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @MainActor
    private func makeAboutWindowController() -> NSWindowController {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About AllTheThings"
        window.canHide = true
        window.isRestorable = false

        let logoView = NSImageView()
        logoView.translatesAutoresizingMaskIntoConstraints = false
        logoView.image = gameCoreTechLogo()
        logoView.imageScaling = .scaleProportionallyUpOrDown
        logoView.imageAlignment = .alignCenter

        let titleLabel = NSTextField(labelWithString: "AllTheThings")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.textColor = .labelColor

        let versionLabel = NSTextField(labelWithString: versionText())
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        versionLabel.font = .systemFont(ofSize: 13, weight: .regular)
        versionLabel.alignment = .center
        versionLabel.textColor = .secondaryLabelColor

        let makerLabel = NSTextField(labelWithString: "Made by Game Core Tech")
        makerLabel.translatesAutoresizingMaskIntoConstraints = false
        makerLabel.font = .systemFont(ofSize: 15, weight: .medium)
        makerLabel.alignment = .center
        makerLabel.textColor = .labelColor

        let websiteButton = makeLinkButton(
            title: "gamecoretech.com",
            action: #selector(openGameCoreTechWebsite(_:))
        )
        let githubButton = makeLinkButton(
            title: "github.com/MikeMarcin/AllTheThings",
            action: #selector(openGitHubRepository(_:))
        )

        let linkStack = NSStackView(views: [websiteButton, githubButton])
        linkStack.translatesAutoresizingMaskIntoConstraints = false
        linkStack.orientation = .vertical
        linkStack.alignment = .centerX
        linkStack.spacing = 6

        let contentStack = NSStackView(views: [
            logoView,
            titleLabel,
            versionLabel,
            makerLabel,
            linkStack
        ])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = 10
        contentStack.setCustomSpacing(18, after: logoView)
        contentStack.setCustomSpacing(20, after: versionLabel)

        let contentView = NSView()
        contentView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            logoView.widthAnchor.constraint(equalToConstant: 250),
            logoView.heightAnchor.constraint(equalToConstant: 250),
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 34),
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -28)
        ])

        window.contentView = contentView
        window.center()

        return NSWindowController(window: window)
    }

    @MainActor
    private func makeLinkButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: 13, weight: .regular)
        button.contentTintColor = .linkColor
        button.setButtonType(.momentaryChange)
        return button
    }

    @MainActor
    private func gameCoreTechLogo() -> NSImage? {
        if let url = Bundle.main.url(forResource: "GameCoreTechLogo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        return NSApp.applicationIconImage
    }

    private func versionText() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String

        switch (version, build) {
        case let (.some(version), .some(build)):
            return "Version \(version) (\(build))"
        case let (.some(version), .none):
            return "Version \(version)"
        default:
            return "Version unavailable"
        }
    }

    private func open(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    private func makeThirdPartyNoticesWindowController() -> NSWindowController {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Third-Party Notices"
        window.canHide = true
        window.isRestorable = false
        window.contentMinSize = NSSize(width: 520, height: 360)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.string = ThirdPartyNotices.text
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 18, height: 16)
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView

        let contentView = NSView()
        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        window.contentView = contentView
        window.center()

        return NSWindowController(window: window)
    }
}
