import AppKit
import ATTCore

// AppKit invokes these Objective-C delegate hooks during startup; hop to the
// main queue before touching Swift @MainActor AppKit APIs.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let allowMultipleInstancesKey = "ATTAllowMultipleInstances"
    private static let activationRequestNotification = Notification.Name("com.allthethings.app.activateExistingInstance")

    private let defaults = UserDefaults.standard
    private var windowController: SearchWindowController?
    private var allowMultipleInstancesMenuItem: NSMenuItem?

    override init() {
        defaults.register(defaults: [
            Self.allowMultipleInstancesKey: false
        ])
        super.init()

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleActivationRequest(_:)),
            name: Self.activationRequestNotification,
            object: Bundle.main.bundleIdentifier
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.appearance = NSAppearance(named: .darkAqua)
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
        showPrimaryWindow(activate: true)
    }

    @MainActor
    private func showPrimaryWindow(activate: Bool) {
        let controller: SearchWindowController
        if let existingController = windowController {
            controller = existingController
        } else {
            let newController = SearchWindowController(index: FileIndex())
            windowController = newController
            controller = newController
        }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if activate {
            NSApp.activate()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        performSelector(onMainThread: #selector(showPrimaryWindowFromActivationRequest), with: nil, waitUntilDone: false)
        return true
    }

    private var allowsMultipleInstances: Bool {
        defaults.bool(forKey: Self.allowMultipleInstancesKey)
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
        showPrimaryWindow(activate: true)
    }

    @objc @MainActor private func toggleAllowMultipleInstances(_ sender: NSMenuItem) {
        defaults.set(!allowsMultipleInstances, forKey: Self.allowMultipleInstancesKey)
        defaults.synchronize()
        updateSettingsMenuItems()
    }

    @MainActor
    private func updateSettingsMenuItems() {
        allowMultipleInstancesMenuItem?.state = allowsMultipleInstances ? .on : .off
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @MainActor
    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About AllTheThings", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())

        let allowMultipleItem = NSMenuItem(
            title: "Allow Multiple Instances",
            action: #selector(toggleAllowMultipleInstances(_:)),
            keyEquivalent: ""
        )
        allowMultipleItem.target = self
        appMenu.addItem(allowMultipleItem)
        allowMultipleInstancesMenuItem = allowMultipleItem
        updateSettingsMenuItems()

        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit AllTheThings", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }
}
