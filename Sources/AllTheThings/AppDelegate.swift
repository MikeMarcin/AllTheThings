import AppKit
import ATTCore
import CoreServices

// AppKit invokes these Objective-C delegate hooks during startup; hop to the
// main queue before touching Swift @MainActor AppKit APIs.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var didPresentGlobalHotKeyRegistrationError = false

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
        configureGlobalHotKey(presentsErrors: !launchedAsLoginItem)
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
    }

    @discardableResult
    @MainActor
    private func showPrimaryWindow(activate: Bool) -> NSWindow? {
        let controller: SearchWindowController
        if let existingController = windowController {
            controller = existingController
        } else {
            let newController = SearchWindowController(index: fileIndex)
            windowController = newController
            controller = newController
        }

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
    private func configureGlobalHotKey(presentsErrors: Bool = false) {
        let controller = GlobalHotKeyController { [weak self] in
            Task { @MainActor in
                self?.focusSearchFromHotKey()
            }
        }
        globalHotKeyController = controller
        applyGlobalHotKeySettings(presentsErrors: presentsErrors)
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
    private func focusSearchFromHotKey() {
        _ = showPrimaryWindow(activate: true)
        windowController?.focusSearchField(selectText: true)
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
        let event = NSApp.currentEvent
        let shouldShowMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if shouldShowMenu {
            showStatusMenu(relativeTo: sender)
        } else {
            focusSearchFromHotKey()
        }
    }

    @objc private func globalSearchHotKeyDidChange(_ notification: Notification) {
        performSelector(onMainThread: #selector(applyGlobalHotKeySettingsFromNotification), with: nil, waitUntilDone: false)
    }

    @objc @MainActor private func applyGlobalHotKeySettingsFromNotification() {
        applyGlobalHotKeySettings()
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
    func showSettings(section: SettingsSection = .general) {
        presentSettingsWindow(section: section)
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
                "exportKind": .publicString(kind),
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
                        "exportKind": .publicString(kind),
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
    private func presentSettingsWindow(section: SettingsSection = .general) {
        let controller: SettingsWindowController
        if let existingController = settingsWindowController {
            controller = existingController
        } else {
            controller = SettingsWindowController(defaults: defaults)
            settingsWindowController = controller
        }

        controller.selectSection(section)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
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
                    guard AppSettings.indexingSetupCompleted(defaults: self.defaults) else { return }
                    let roots = AppSettings.indexedRoots(defaults: self.defaults)
                    guard !roots.isEmpty else { return }
                    self.fileIndex.setPublishesSearchableSnapshotsDuringScan(false)
                    self.fileIndex.replaceRootsAndRebuild(roots, mode: .fresh)
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
            button.toolTip = "AllTheThings - Click to focus search. Control-click for menu."
            button.target = self
            button.action = #selector(activateStatusItem(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let menu = NSMenu(title: "AllTheThings")
        menu.delegate = self

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
            return
        }

        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        statusMenu = nil
    }

    private static func makeStatusIconImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let scale = rect.width / size.width
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
            }
            func radians(_ degrees: CGFloat) -> CGFloat {
                degrees * .pi / 180
            }

            let contrastUnderlay = NSColor.labelColor.withAlphaComponent(0.24).cgColor
            let cyan = CGColor(red: 0.08, green: 0.88, blue: 1.0, alpha: 1.0)
            let blue = CGColor(red: 0.22, green: 0.40, blue: 1.0, alpha: 0.94)
            let magenta = CGColor(red: 1.0, green: 0.14, blue: 0.84, alpha: 1.0)
            let highlight = CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.52)
            let center = point(7.3, 10.4)
            let radius = 4.35 * scale
            let ringWidth = 2.55 * scale
            let handleWidth = 3.15 * scale

            context.setLineCap(.round)
            context.setLineJoin(.round)

            context.setStrokeColor(contrastUnderlay)
            context.setLineWidth(4.9 * scale)
            context.move(to: point(10.8, 6.9))
            context.addLine(to: point(15.1, 2.6))
            context.strokePath()

            context.setStrokeColor(contrastUnderlay)
            context.setLineWidth(4.3 * scale)
            context.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            context.strokePath()

            context.setStrokeColor(magenta)
            context.setLineWidth(handleWidth)
            context.move(to: point(10.8, 6.9))
            context.addLine(to: point(15.1, 2.6))
            context.strokePath()

            context.setStrokeColor(cyan)
            context.setLineWidth(ringWidth)
            context.addArc(center: center, radius: radius, startAngle: radians(14), endAngle: radians(204), clockwise: false)
            context.strokePath()

            context.setStrokeColor(blue)
            context.setLineWidth(ringWidth)
            context.addArc(center: center, radius: radius, startAngle: radians(204), endAngle: radians(298), clockwise: false)
            context.strokePath()

            context.setStrokeColor(magenta)
            context.setLineWidth(ringWidth)
            context.addArc(center: center, radius: radius, startAngle: radians(298), endAngle: radians(374), clockwise: false)
            context.strokePath()

            context.setStrokeColor(highlight)
            context.setLineWidth(0.85 * scale)
            context.addArc(center: center, radius: 3.25 * scale, startAngle: radians(112), endAngle: radians(158), clockwise: false)
            context.strokePath()

            return true
        }
        image.isTemplate = false
        image.cacheMode = .never
        return image
    }

    @MainActor
    private func showStatusMenu(relativeTo button: NSStatusBarButton) {
        guard let menu = statusMenu else { return }
        menuNeedsUpdate(menu)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
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
