import AppKit
import ATTCore
import CoreServices

// AppKit invokes these Objective-C delegate hooks during startup; hop to the
// main queue before touching Swift @MainActor AppKit APIs.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let activationRequestNotification = Notification.Name("com.allthethings.app.activateExistingInstance")

    private let defaults = UserDefaults.standard
    private var windowController: SearchWindowController?
    private var settingsWindowController: NSWindowController?
    private var aboutWindowController: NSWindowController?
    private var noticesWindowController: NSWindowController?
    private var globalHotKeyController: GlobalHotKeyController?
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
        configureMainMenu()
        let launchedAsLoginItem = Self.launchedAsLoginItem()
        let window = launchedAsLoginItem ? nil : showPrimaryWindow(activate: true)
        configureGlobalHotKey(presentsErrors: !launchedAsLoginItem)
        if !launchedAsLoginItem {
            ReleaseUpdater.shared.checkAutomaticallyIfNeeded(presentingWindow: window)
        }
    }

    @discardableResult
    @MainActor
    private func showPrimaryWindow(activate: Bool) -> NSWindow? {
        let controller: SearchWindowController
        if let existingController = windowController {
            controller = existingController
        } else {
            let newController = SearchWindowController(index: FileIndex(
                loadsSnapshotImmediately: false,
                exclusionPatterns: AppSettings.exclusionPatterns(defaults: defaults)
            ))
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        performSelector(onMainThread: #selector(showPrimaryWindowFromActivationRequest), with: nil, waitUntilDone: false)
        return true
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
            if presentsErrors {
                presentGlobalHotKeyEnableConfirmation()
            }
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
    private func presentGlobalHotKeyEnableConfirmation() {
        let hotKey = AppSettings.globalSearchHotKey(defaults: defaults)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Enable \(hotKey.displayString) for global search?"
        alert.informativeText = "AllTheThings can claim this shortcut system-wide while it is running. If another app or macOS feature already uses this shortcut, choose a different shortcut in Settings instead."
        alert.addButton(withTitle: "Enable Shortcut")
        alert.addButton(withTitle: "Choose Shortcut...")
        alert.addButton(withTitle: "Not Now")

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.enableConfirmedGlobalHotKey(hotKey)
            case .alertSecondButtonReturn:
                AppSettings.saveGlobalSearchHotKey(enabled: false, hotKey: hotKey, defaults: self.defaults)
                self.showSettingsWindow(nil)
            default:
                AppSettings.saveGlobalSearchHotKey(enabled: false, hotKey: hotKey, defaults: self.defaults)
            }
        }

        if let window = windowController?.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    @MainActor
    private func enableConfirmedGlobalHotKey(_ hotKey: GlobalHotKey) {
        do {
            try globalHotKeyController?.configure(isEnabled: true, hotKey: hotKey)
            AppSettings.saveGlobalSearchHotKey(enabled: true, hotKey: hotKey, defaults: defaults)
        } catch {
            AppSettings.saveGlobalSearchHotKey(enabled: false, hotKey: hotKey, defaults: defaults)
            presentGlobalHotKeyRegistrationError(error)
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

    @objc private func globalSearchHotKeyDidChange(_ notification: Notification) {
        performSelector(onMainThread: #selector(applyGlobalHotKeySettingsFromNotification), with: nil, waitUntilDone: false)
    }

    @objc @MainActor private func applyGlobalHotKeySettingsFromNotification() {
        applyGlobalHotKeySettings()
    }

    @objc private func themePreferenceDidChange(_ notification: Notification) {
        Task { @MainActor in
            AppTheme.applyCurrent()
        }
    }

    @objc @MainActor private func checkForUpdates(_ sender: Any?) {
        ReleaseUpdater.shared.checkForUpdates(presentingWindow: windowController?.window, userInitiated: true)
    }

    @objc @MainActor private func showSettingsWindow(_ sender: Any?) {
        let controller: NSWindowController
        if let existingController = settingsWindowController {
            controller = existingController
        } else {
            controller = SettingsWindowController(defaults: defaults)
            settingsWindowController = controller
        }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc @MainActor private func toggleHiddenFiles(_ sender: Any?) {
        let showHiddenFiles = !defaults.bool(forKey: AppSettings.showHiddenFilesKey)
        defaults.set(showHiddenFiles, forKey: AppSettings.showHiddenFilesKey)
        defaults.synchronize()
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
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)

        NSApp.mainMenu = mainMenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.action == #selector(toggleHiddenFiles(_:)) {
            item.state = defaults.bool(forKey: AppSettings.showHiddenFilesKey) ? .on : .off
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
