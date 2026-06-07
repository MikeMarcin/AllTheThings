import AppKit
import ATTCore
import Carbon.HIToolbox

@MainActor
final class SettingsWindowController: NSWindowController {
    init(
        defaults: UserDefaults = .standard,
        index: FileIndex,
        reindexHandler: @escaping @MainActor () -> Void
    ) {
        let contentSize = NSSize(width: 780, height: 640)
        let viewController = SettingsViewController(
            defaults: defaults,
            index: index,
            reindexHandler: reindexHandler
        )
        viewController.preferredContentSize = contentSize
        let window = SettingsWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isRestorable = false
        window.contentMinSize = NSSize(width: 700, height: 560)
        window.contentViewController = viewController
        window.setContentSize(contentSize)
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func selectSection(_ section: SettingsSection) {
        (contentViewController as? SettingsViewController)?.selectSection(section)
    }
}

private final class SettingsWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if shouldClose(for: event) {
            close()
            return
        }

        super.sendEvent(event)
    }

    private func shouldClose(for event: NSEvent) -> Bool {
        guard
            event.type == .keyDown,
            event.keyCode == UInt16(kVK_Escape),
            event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
            !(firstResponder is HotKeyRecorderView)
        else {
            return false
        }

        return true
    }
}

enum SettingsSection {
    case general
    case appearance
    case indexedFolders

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .general: "General"
        case .indexedFolders: "Indexed Folders"
        }
    }

    var symbolName: String {
        switch self {
        case .appearance: "paintpalette"
        case .general: "gearshape"
        case .indexedFolders: "folder"
        }
    }
}

private extension DiagnosticLogLevel {
    var settingsTitle: String {
        switch self {
        case .info: "Standard"
        case .diagnostic: "Verbose"
        case .debug, .warning, .error: rawValue.capitalized
        }
    }
}

@MainActor
private final class SettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let defaults: UserDefaults
    private let index: FileIndex
    private let reindexHandler: @MainActor () -> Void
    private let contentContainer = NSView()
    private let appearanceSidebarRow = SidebarRow(section: .appearance)
    private let generalSidebarRow = SidebarRow(section: .general)
    private let indexedFoldersSidebarRow = SidebarRow(section: .indexedFolders)
    private let themeSegmentedControl = NSSegmentedControl(
        labels: AppThemePreference.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let fontFamilyPopUpButton = NSPopUpButton()
    private let fontSizeStepper = NSStepper()
    private let fontSizeValueLabel = NSTextField(labelWithString: "")
    private let resetAppFontButton = NSButton()
    private let lightMatchColorPaletteControl = MatchColorPaletteControl()
    private let darkMatchColorPaletteControl = MatchColorPaletteControl()
    private let resetLightMatchColorsButton = NSButton()
    private let resetDarkMatchColorsButton = NSButton()
    private let globalHotKeySwitch = NSSwitch()
    private let changeGlobalHotKeyButton = NSButton()
    private let globalAppSearchHotKeySwitch = NSSwitch()
    private let changeGlobalAppSearchHotKeyButton = NSButton()
    private let launchAtLoginSwitch = NSSwitch()
    private let menuBarIconSwitch = NSSwitch()
    private let highlightSearchTextSwitch = NSSwitch()
    private let showHiddenFilesSwitch = NSSwitch()
    private let allowMultipleInstancesSwitch = NSSwitch()
    private let automaticallyCheckForUpdatesSwitch = NSSwitch()
    private let diagnosticLogLevelSegmentedControl = NSSegmentedControl(
        labels: [DiagnosticLogLevel.info, .diagnostic].map(\.settingsTitle),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let fullDiskAccessStatusIconView = NSImageView()
    private let fullDiskAccessStatusLabel = NSTextField(labelWithString: "")
    private let fullDiskAccessExplanationLabel = NSTextField(labelWithString: "")
    private let openFullDiskAccessSettingsButton = NSButton()
    private let recheckFullDiskAccessButton = NSButton()
    private let indexedFoldersAccessWarningView = SettingsWarningView()
    private let indexedFoldersAccessWarningLabel = NSTextField(labelWithString: "")
    private let rootsTableView = NSTableView()
    private let addRootButton = NSButton()
    private let resetRootsButton = NSButton()
    private let appSearchRootsTableView = NSTableView()
    private let addAppSearchRootButton = NSButton()
    private let resetAppSearchRootsButton = NSButton()
    private let indexSizeValueLabel = NSTextField(labelWithString: "")
    private let indexCreatedValueLabel = NSTextField(labelWithString: "")
    private let reindexButton = NSButton()
    private let exclusionsTableView = NSTableView()
    private let addExclusionButton = NSButton()
    private let resetExclusionsButton = NSButton()
    private let exclusionHelpButton = NSButton()
    private var pageViews: [SettingsSection: NSView] = [:]
    private var selectedSection = SettingsSection.general
    private var indexedRoots: [URL] = []
    private var appSearchRoots: [URL] = []
    private var exclusionPatterns: [String] = []
    private var indexedRootsCardHeightConstraint: NSLayoutConstraint?
    private var appSearchRootsCardHeightConstraint: NSLayoutConstraint?
    private var indexedRootsCardTopConstraint: NSLayoutConstraint?
    private var exclusionPatternsCardHeightConstraint: NSLayoutConstraint?
    private var indexedFoldersAccessWarningCollapsedHeightConstraint: NSLayoutConstraint?

    private static let exclusionPatternFieldIdentifier = NSUserInterfaceItemIdentifier("exclusionPatternField")
    private static let indexedRootPasteboardType = NSPasteboard.PasteboardType("com.allthethings.settings.indexed-root-row")
    private static let appSearchRootPasteboardType = NSPasteboard.PasteboardType("com.allthethings.settings.app-search-root-row")
    private static let exclusionPatternPasteboardType = NSPasteboard.PasteboardType("com.allthethings.settings.exclusion-pattern-row")
    private static let settingsTableRowHeight: CGFloat = 42
    private static let indexedRootsMaximumVisibleRows = 8
    private static let appSearchRootsMaximumVisibleRows = 5
    private static let exclusionPatternsMaximumVisibleRows = 10
    private static let diagnosticDetailLevels: [DiagnosticLogLevel] = [.info, .diagnostic]

    init(
        defaults: UserDefaults,
        index: FileIndex,
        reindexHandler: @escaping @MainActor () -> Void
    ) {
        self.defaults = defaults
        self.index = index
        self.reindexHandler = reindexHandler
        AppSettings.registerDefaults(defaults)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = ThemedBackgroundView(frame: NSRect(x: 0, y: 0, width: 780, height: 640))
        rootView.appearanceDidChange = { [weak self] in
            self?.updateMatchColorControls()
        }
        view = rootView
        buildInterface()
        updateControls()
        selectSection(.general)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(indexedRootsDidChange(_:)),
            name: AppSettings.indexedRootsDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appSearchRootsDidChange(_:)),
            name: AppSettings.appSearchRootsDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(exclusionPatternsDidChange(_:)),
            name: AppSettings.exclusionPatternsDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange(_:)),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func buildInterface() {
        let sidebar = makeSidebar()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(sidebar)
        view.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 190),

            contentContainer.topAnchor.constraint(equalTo: view.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func makeSidebar() -> NSView {
        let sidebar = NSVisualEffectView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active

        let stack = NSStackView(views: [generalSidebarRow, appearanceSidebarRow, indexedFoldersSidebarRow])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 6

        for row in [appearanceSidebarRow, generalSidebarRow, indexedFoldersSidebarRow] {
            row.target = self
            row.action = #selector(selectSidebarRow(_:))
        }

        sidebar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: sidebar.safeAreaLayoutGuide.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            appearanceSidebarRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            generalSidebarRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            indexedFoldersSidebarRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        return sidebar
    }

    @objc private func selectSidebarRow(_ sender: SidebarRow) {
        selectSection(sender.section)
    }

    fileprivate func selectSection(_ section: SettingsSection) {
        selectedSection = section
        appearanceSidebarRow.isSelected = section == .appearance
        generalSidebarRow.isSelected = section == .general
        indexedFoldersSidebarRow.isSelected = section == .indexedFolders
        renderSelectedSection()
    }

    private func renderSelectedSection() {
        let page = pageView(for: selectedSection)
        if page.superview == nil {
            contentContainer.addSubview(page)
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                page.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                page.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
            ])
        }

        for (section, view) in pageViews {
            view.isHidden = section != selectedSection
        }

        if selectedSection == .indexedFolders {
            renderIndexedRoots()
            renderAppSearchRoots()
            renderExclusionPatterns()
        }
    }

    private func pageView(for section: SettingsSection) -> NSView {
        if let page = pageViews[section] {
            return page
        }

        let page: NSView
        switch section {
        case .appearance:
            page = makeAppearancePage()
        case .general:
            page = makeGeneralPage()
        case .indexedFolders:
            page = makeIndexedFoldersPage()
        }

        pageViews[section] = page
        return page
    }

    private func makePageScrollView() -> (NSScrollView, NSView) {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let contentView = FlippedView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentView

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor)
        ])

        return (scrollView, contentView)
    }

    private func makeAppearancePage() -> NSView {
        let (scrollView, contentView) = makePageScrollView()

        let sectionLabel = makeSectionLabel("Theme")
        let typographyLabel = makeSectionLabel("Typography")
        let matchColorsLabel = makeSectionLabel("Match Colors")

        configureThemeControl()
        configureFontControls()
        configureMatchColorControls()

        let themeCard = makeSettingsCard(rows: [
            makeControlRow(
                title: "Theme",
                detail: "Choose the app appearance.",
                control: themeSegmentedControl
            )
        ])
        let typographyCard = makeSettingsCard(rows: [
            makeControlRow(
                title: "Font family",
                detail: "Choose the app text family.",
                control: fontFamilyPopUpButton
            ),
            makeControlRow(
                title: "Font size",
                detail: "Adjust search results and app controls.",
                control: makeFontSizeControl()
            )
        ])
        let matchColorsCard = makeSettingsCard(rows: [
            makeControlRow(
                title: "Light theme",
                detail: "Colors used on light backgrounds.",
                control: makeMatchColorPaletteRow(
                    paletteControl: lightMatchColorPaletteControl,
                    resetButton: resetLightMatchColorsButton
                )
            ),
            makeControlRow(
                title: "Dark theme",
                detail: "Colors used on dark backgrounds.",
                control: makeMatchColorPaletteRow(
                    paletteControl: darkMatchColorPaletteControl,
                    resetButton: resetDarkMatchColorsButton
                )
            )
        ])

        contentView.addSubview(sectionLabel)
        contentView.addSubview(themeCard)
        contentView.addSubview(typographyLabel)
        contentView.addSubview(typographyCard)
        contentView.addSubview(matchColorsLabel)
        contentView.addSubview(matchColorsCard)

        NSLayoutConstraint.activate([
            sectionLabel.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor, constant: 26),
            sectionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 36),
            sectionLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -36),

            themeCard.topAnchor.constraint(equalTo: sectionLabel.bottomAnchor, constant: 12),
            themeCard.leadingAnchor.constraint(equalTo: sectionLabel.leadingAnchor),
            themeCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -36),

            typographyLabel.topAnchor.constraint(equalTo: themeCard.bottomAnchor, constant: 28),
            typographyLabel.leadingAnchor.constraint(equalTo: themeCard.leadingAnchor),
            typographyLabel.trailingAnchor.constraint(lessThanOrEqualTo: themeCard.trailingAnchor),

            typographyCard.topAnchor.constraint(equalTo: typographyLabel.bottomAnchor, constant: 12),
            typographyCard.leadingAnchor.constraint(equalTo: themeCard.leadingAnchor),
            typographyCard.trailingAnchor.constraint(equalTo: themeCard.trailingAnchor),

            matchColorsLabel.topAnchor.constraint(equalTo: typographyCard.bottomAnchor, constant: 28),
            matchColorsLabel.leadingAnchor.constraint(equalTo: themeCard.leadingAnchor),
            matchColorsLabel.trailingAnchor.constraint(lessThanOrEqualTo: themeCard.trailingAnchor),

            matchColorsCard.topAnchor.constraint(equalTo: matchColorsLabel.bottomAnchor, constant: 12),
            matchColorsCard.leadingAnchor.constraint(equalTo: themeCard.leadingAnchor),
            matchColorsCard.trailingAnchor.constraint(equalTo: themeCard.trailingAnchor),
            matchColorsCard.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24)
        ])

        return scrollView
    }

    private func makeGeneralPage() -> NSView {
        let (scrollView, contentView) = makePageScrollView()

        let sectionLabel = makeSectionLabel("Application")
        let diagnosticsLabel = makeSectionLabel("Diagnostics")

        configureSwitch(globalHotKeySwitch, action: #selector(toggleGlobalHotKey(_:)))
        configureGlobalHotKeyButton()
        configureSwitch(globalAppSearchHotKeySwitch, action: #selector(toggleGlobalAppSearchHotKey(_:)))
        configureGlobalAppSearchHotKeyButton()
        configureSwitch(launchAtLoginSwitch, action: #selector(toggleLaunchAtLogin(_:)))
        configureSwitch(menuBarIconSwitch, action: #selector(toggleMenuBarIcon(_:)))
        configureSwitch(highlightSearchTextSwitch, action: #selector(toggleHighlightSearchText(_:)))
        configureSwitch(showHiddenFilesSwitch, action: #selector(toggleShowHiddenFiles(_:)))
        configureSwitch(allowMultipleInstancesSwitch, action: #selector(toggleAllowMultipleInstances(_:)))
        configureSwitch(automaticallyCheckForUpdatesSwitch, action: #selector(toggleAutomaticallyCheckForUpdates(_:)))
        configureDiagnosticLogLevelControl()

        let settingsCard = makeSettingsCard(rows: [
            makeControlRow(
                title: "Global search hotkey",
                detail: "Focus the search window from any app.",
                control: makeGlobalHotKeyControl()
            ),
            makeControlRow(
                title: "Global app search hotkey",
                detail: "Open search with app: ready to launch applications.",
                control: makeGlobalAppSearchHotKeyControl()
            ),
            makeControlRow(
                title: "Launch at login",
                detail: "Start quietly when you sign in so the global hotkey is ready.",
                control: launchAtLoginSwitch
            ),
            makeControlRow(
                title: "Menu bar icon",
                detail: "Show the menu bar loupe for quick search access.",
                control: menuBarIconSwitch
            ),
            makeControlRow(
                title: "Highlight search text",
                detail: "Highlight matching text in file names while searching.",
                control: highlightSearchTextSwitch
            ),
            makeControlRow(
                title: "Show hidden files",
                detail: "Include dotfiles and hidden items in search results.",
                control: showHiddenFilesSwitch
            ),
            makeControlRow(
                title: "Allow multiple instances",
                detail: "Open a new app instance instead of activating the existing one.",
                control: allowMultipleInstancesSwitch
            ),
            makeControlRow(
                title: "Automatically check for updates",
                detail: "Look for new GitHub releases in the background.",
                control: automaticallyCheckForUpdatesSwitch
            )
        ])
        let diagnosticsCard = makeSettingsCard(rows: [
            makeControlRow(
                title: "Diagnostic detail",
                detail: "Choose how much path-heavy diagnostic context is saved locally.",
                control: diagnosticLogLevelSegmentedControl
            )
        ])

        contentView.addSubview(sectionLabel)
        contentView.addSubview(settingsCard)
        contentView.addSubview(diagnosticsLabel)
        contentView.addSubview(diagnosticsCard)

        NSLayoutConstraint.activate([
            sectionLabel.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor, constant: 26),
            sectionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 36),
            sectionLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -36),

            settingsCard.topAnchor.constraint(equalTo: sectionLabel.bottomAnchor, constant: 12),
            settingsCard.leadingAnchor.constraint(equalTo: sectionLabel.leadingAnchor),
            settingsCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -36),

            diagnosticsLabel.topAnchor.constraint(equalTo: settingsCard.bottomAnchor, constant: 28),
            diagnosticsLabel.leadingAnchor.constraint(equalTo: settingsCard.leadingAnchor),
            diagnosticsLabel.trailingAnchor.constraint(lessThanOrEqualTo: settingsCard.trailingAnchor),

            diagnosticsCard.topAnchor.constraint(equalTo: diagnosticsLabel.bottomAnchor, constant: 12),
            diagnosticsCard.leadingAnchor.constraint(equalTo: settingsCard.leadingAnchor),
            diagnosticsCard.trailingAnchor.constraint(equalTo: settingsCard.trailingAnchor),
            diagnosticsCard.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
        ])

        return scrollView
    }

    private func makeIndexedFoldersPage() -> NSView {
        let (scrollView, contentView) = makePageScrollView()

        let indexLabel = makeSectionLabel("Index")
        configureIndexSummaryControls()
        let indexCard = makeIndexSummaryCard()
        let accessLabel = makeSectionLabel("Folder Access")
        configureFullDiskAccessButtons()
        let fullDiskAccessCard = makeFullDiskAccessCard()

        let rootsHeader = NSStackView()
        rootsHeader.translatesAutoresizingMaskIntoConstraints = false
        rootsHeader.orientation = .horizontal
        rootsHeader.alignment = .centerY
        rootsHeader.spacing = 8

        let rootsLabel = makeSectionLabel("Folders")

        configureIconButton(
            resetRootsButton,
            symbol: "arrow.counterclockwise",
            tooltip: "Reset indexed folders to defaults",
            action: #selector(resetIndexedRoots(_:))
        )
        configureAddButton(
            addRootButton,
            tooltip: "Add indexed folder",
            action: #selector(addIndexedRoot(_:))
        )

        let rootsHeaderSpacer = NSView()
        rootsHeaderSpacer.translatesAutoresizingMaskIntoConstraints = false
        rootsHeader.addArrangedSubview(rootsLabel)
        rootsHeader.addArrangedSubview(rootsHeaderSpacer)
        rootsHeader.addArrangedSubview(resetRootsButton)
        rootsHeader.addArrangedSubview(addRootButton)

        let accessWarning = makeIndexedFoldersAccessWarningView()
        let rootsCard = makeIndexedRootsCard()

        let appSearchHeader = NSStackView()
        appSearchHeader.translatesAutoresizingMaskIntoConstraints = false
        appSearchHeader.orientation = .horizontal
        appSearchHeader.alignment = .centerY
        appSearchHeader.spacing = 8

        let appSearchLabel = makeSectionLabel("Application Search")

        configureIconButton(
            resetAppSearchRootsButton,
            symbol: "arrow.counterclockwise",
            tooltip: "Reset app search folders to defaults",
            action: #selector(resetAppSearchRoots(_:))
        )
        configureAddButton(
            addAppSearchRootButton,
            tooltip: "Add app search folder",
            action: #selector(addAppSearchRoot(_:))
        )

        let appSearchHeaderSpacer = NSView()
        appSearchHeaderSpacer.translatesAutoresizingMaskIntoConstraints = false
        appSearchHeader.addArrangedSubview(appSearchLabel)
        appSearchHeader.addArrangedSubview(appSearchHeaderSpacer)
        appSearchHeader.addArrangedSubview(resetAppSearchRootsButton)
        appSearchHeader.addArrangedSubview(addAppSearchRootButton)

        let appSearchCard = makeAppSearchRootsCard()

        let exclusionsHeader = NSStackView()
        exclusionsHeader.translatesAutoresizingMaskIntoConstraints = false
        exclusionsHeader.orientation = .horizontal
        exclusionsHeader.alignment = .centerY
        exclusionsHeader.spacing = 8

        let exclusionsLabel = makeSectionLabel("Excluded paths")

        exclusionHelpButton.translatesAutoresizingMaskIntoConstraints = false
        exclusionHelpButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Ignore pattern help")
        exclusionHelpButton.title = ""
        exclusionHelpButton.isBordered = false
        exclusionHelpButton.contentTintColor = .secondaryLabelColor
        exclusionHelpButton.toolTip = "Ignore pattern help"
        exclusionHelpButton.target = self
        exclusionHelpButton.action = #selector(showExclusionPatternHelp(_:))

        configureIconButton(
            resetExclusionsButton,
            symbol: "arrow.counterclockwise",
            tooltip: "Reset excluded paths to defaults",
            action: #selector(resetExclusionPatterns(_:))
        )
        configureAddButton(
            addExclusionButton,
            tooltip: "Add excluded path",
            action: #selector(addExclusionPattern(_:))
        )

        let exclusionsHeaderSpacer = NSView()
        exclusionsHeaderSpacer.translatesAutoresizingMaskIntoConstraints = false
        exclusionsHeader.addArrangedSubview(exclusionsLabel)
        exclusionsHeader.addArrangedSubview(exclusionHelpButton)
        exclusionsHeader.addArrangedSubview(exclusionsHeaderSpacer)
        exclusionsHeader.addArrangedSubview(resetExclusionsButton)
        exclusionsHeader.addArrangedSubview(addExclusionButton)

        let exclusionsCard = makeExclusionPatternsCard()
        let contentBottomConstraint = exclusionsCard.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
        contentBottomConstraint.priority = .defaultLow
        let warningCollapsedHeightConstraint = accessWarning.heightAnchor.constraint(equalToConstant: 0)
        let rootsCardTopConstraint = rootsCard.topAnchor.constraint(equalTo: accessWarning.bottomAnchor, constant: 10)
        indexedFoldersAccessWarningCollapsedHeightConstraint = warningCollapsedHeightConstraint
        indexedRootsCardTopConstraint = rootsCardTopConstraint

        contentView.addSubview(indexLabel)
        contentView.addSubview(indexCard)
        contentView.addSubview(accessLabel)
        contentView.addSubview(fullDiskAccessCard)
        contentView.addSubview(rootsHeader)
        contentView.addSubview(accessWarning)
        contentView.addSubview(rootsCard)
        contentView.addSubview(appSearchHeader)
        contentView.addSubview(appSearchCard)
        contentView.addSubview(exclusionsHeader)
        contentView.addSubview(exclusionsCard)

        NSLayoutConstraint.activate([
            indexLabel.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor, constant: 26),
            indexLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 36),
            indexLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -36),

            indexCard.topAnchor.constraint(equalTo: indexLabel.bottomAnchor, constant: 12),
            indexCard.leadingAnchor.constraint(equalTo: indexLabel.leadingAnchor),
            indexCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -36),

            accessLabel.topAnchor.constraint(equalTo: indexCard.bottomAnchor, constant: 28),
            accessLabel.leadingAnchor.constraint(equalTo: indexCard.leadingAnchor),
            accessLabel.trailingAnchor.constraint(lessThanOrEqualTo: indexCard.trailingAnchor),

            fullDiskAccessCard.topAnchor.constraint(equalTo: accessLabel.bottomAnchor, constant: 12),
            fullDiskAccessCard.leadingAnchor.constraint(equalTo: indexCard.leadingAnchor),
            fullDiskAccessCard.trailingAnchor.constraint(equalTo: indexCard.trailingAnchor),

            rootsHeader.topAnchor.constraint(equalTo: fullDiskAccessCard.bottomAnchor, constant: 28),
            rootsHeader.leadingAnchor.constraint(equalTo: indexCard.leadingAnchor),
            rootsHeader.trailingAnchor.constraint(equalTo: indexCard.trailingAnchor),
            resetRootsButton.widthAnchor.constraint(equalToConstant: 28),
            resetRootsButton.heightAnchor.constraint(equalToConstant: 24),
            addRootButton.widthAnchor.constraint(equalToConstant: 74),
            addRootButton.heightAnchor.constraint(equalToConstant: 30),

            accessWarning.topAnchor.constraint(equalTo: rootsHeader.bottomAnchor, constant: 10),
            accessWarning.leadingAnchor.constraint(equalTo: rootsHeader.leadingAnchor),
            accessWarning.trailingAnchor.constraint(equalTo: rootsHeader.trailingAnchor),
            warningCollapsedHeightConstraint,

            rootsCardTopConstraint,
            rootsCard.leadingAnchor.constraint(equalTo: rootsHeader.leadingAnchor),
            rootsCard.trailingAnchor.constraint(equalTo: rootsHeader.trailingAnchor),

            appSearchHeader.topAnchor.constraint(equalTo: rootsCard.bottomAnchor, constant: 28),
            appSearchHeader.leadingAnchor.constraint(equalTo: rootsCard.leadingAnchor),
            appSearchHeader.trailingAnchor.constraint(equalTo: rootsCard.trailingAnchor),
            resetAppSearchRootsButton.widthAnchor.constraint(equalToConstant: 28),
            resetAppSearchRootsButton.heightAnchor.constraint(equalToConstant: 24),
            addAppSearchRootButton.widthAnchor.constraint(equalToConstant: 74),
            addAppSearchRootButton.heightAnchor.constraint(equalToConstant: 30),

            appSearchCard.topAnchor.constraint(equalTo: appSearchHeader.bottomAnchor, constant: 10),
            appSearchCard.leadingAnchor.constraint(equalTo: appSearchHeader.leadingAnchor),
            appSearchCard.trailingAnchor.constraint(equalTo: appSearchHeader.trailingAnchor),

            exclusionsHeader.topAnchor.constraint(equalTo: appSearchCard.bottomAnchor, constant: 28),
            exclusionsHeader.leadingAnchor.constraint(equalTo: appSearchCard.leadingAnchor),
            exclusionsHeader.trailingAnchor.constraint(equalTo: appSearchCard.trailingAnchor),
            exclusionHelpButton.widthAnchor.constraint(equalToConstant: 20),
            exclusionHelpButton.heightAnchor.constraint(equalToConstant: 20),
            resetExclusionsButton.widthAnchor.constraint(equalToConstant: 28),
            resetExclusionsButton.heightAnchor.constraint(equalToConstant: 24),
            addExclusionButton.widthAnchor.constraint(equalToConstant: 74),
            addExclusionButton.heightAnchor.constraint(equalToConstant: 30),

            exclusionsCard.topAnchor.constraint(equalTo: exclusionsHeader.bottomAnchor, constant: 10),
            exclusionsCard.leadingAnchor.constraint(equalTo: appSearchCard.leadingAnchor),
            exclusionsCard.trailingAnchor.constraint(equalTo: appSearchCard.trailingAnchor),
            exclusionsCard.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24),
            contentBottomConstraint
        ])

        updateIndexSummary()
        updateFullDiskAccessStatus()
        updateIndexedFoldersAccessWarning()
        return scrollView
    }

    private func makeSectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = AppSettings.appFont(defaults: defaults, sizeDelta: 1, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func configureSwitch(_ control: NSSwitch, action: Selector) {
        control.translatesAutoresizingMaskIntoConstraints = false
        control.target = self
        control.action = action
    }

    private func configureIndexSummaryControls() {
        for label in [indexSizeValueLabel, indexCreatedValueLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            label.textColor = .labelColor
            label.alignment = .right
            label.lineBreakMode = .byTruncatingTail
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        configureTextButton(
            reindexButton,
            title: "Reindex",
            symbol: "arrow.clockwise",
            action: #selector(reindexIndexedFolders(_:))
        )

        NSLayoutConstraint.activate([
            indexSizeValueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            indexCreatedValueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
    }

    private func configureThemeControl() {
        themeSegmentedControl.translatesAutoresizingMaskIntoConstraints = false
        themeSegmentedControl.target = self
        themeSegmentedControl.action = #selector(changeThemePreference(_:))
        themeSegmentedControl.toolTip = "Theme"
        themeSegmentedControl.setContentHuggingPriority(.required, for: .horizontal)
        themeSegmentedControl.setContentCompressionResistancePriority(.required, for: .horizontal)

        for segment in 0..<themeSegmentedControl.segmentCount {
            themeSegmentedControl.setWidth(76, forSegment: segment)
        }
    }

    private func configureFontControls() {
        fontFamilyPopUpButton.translatesAutoresizingMaskIntoConstraints = false
        fontFamilyPopUpButton.target = self
        fontFamilyPopUpButton.action = #selector(changeAppFontFamily(_:))
        fontFamilyPopUpButton.setContentHuggingPriority(.required, for: .horizontal)
        fontFamilyPopUpButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        fontFamilyPopUpButton.removeAllItems()
        fontFamilyPopUpButton.addItem(withTitle: "System")
        fontFamilyPopUpButton.lastItem?.representedObject = ""

        for familyName in NSFontManager.shared.availableFontFamilies.sorted() {
            fontFamilyPopUpButton.addItem(withTitle: familyName)
            fontFamilyPopUpButton.lastItem?.representedObject = familyName
        }

        fontSizeStepper.translatesAutoresizingMaskIntoConstraints = false
        fontSizeStepper.minValue = Double(AppSettings.appFontSizeRange.lowerBound)
        fontSizeStepper.maxValue = Double(AppSettings.appFontSizeRange.upperBound)
        fontSizeStepper.increment = 1
        fontSizeStepper.target = self
        fontSizeStepper.action = #selector(changeAppFontSize(_:))

        fontSizeValueLabel.translatesAutoresizingMaskIntoConstraints = false
        fontSizeValueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        fontSizeValueLabel.textColor = .secondaryLabelColor
        fontSizeValueLabel.alignment = .right

        configureIconButton(
            resetAppFontButton,
            symbol: "arrow.counterclockwise",
            tooltip: "Reset font",
            action: #selector(resetAppFont(_:))
        )

        NSLayoutConstraint.activate([
            fontFamilyPopUpButton.widthAnchor.constraint(equalToConstant: 220),
            fontSizeValueLabel.widthAnchor.constraint(equalToConstant: 32)
        ])

        updateFontControls()
    }

    private func makeFontSizeControl() -> NSView {
        let stack = NSStackView(views: [fontSizeStepper, fontSizeValueLabel, resetAppFontButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10

        NSLayoutConstraint.activate([
            resetAppFontButton.widthAnchor.constraint(equalToConstant: 28),
            resetAppFontButton.heightAnchor.constraint(equalToConstant: 24)
        ])

        return stack
    }

    private func updateFontControls() {
        let familyName = AppSettings.appFontFamilyName(defaults: defaults) ?? ""
        let selectedItem = fontFamilyPopUpButton.itemArray.first { ($0.representedObject as? String ?? "") == familyName }
        fontFamilyPopUpButton.select(selectedItem ?? fontFamilyPopUpButton.itemArray.first)

        let fontSize = AppSettings.appFontSize(defaults: defaults)
        fontSizeStepper.doubleValue = Double(fontSize)
        fontSizeValueLabel.stringValue = "\(Int(fontSize))"
    }

    private func configureMatchColorControls() {
        lightMatchColorPaletteControl.configure(defaults: defaults, isDark: false)
        lightMatchColorPaletteControl.onChange = { [weak self] matchClass, color in
            guard let self else { return }
            AppSettings.saveMatchColor(color, for: matchClass, isDark: false, defaults: self.defaults)
        }

        darkMatchColorPaletteControl.configure(defaults: defaults, isDark: true)
        darkMatchColorPaletteControl.onChange = { [weak self] matchClass, color in
            guard let self else { return }
            AppSettings.saveMatchColor(color, for: matchClass, isDark: true, defaults: self.defaults)
        }

        configureIconButton(
            resetLightMatchColorsButton,
            symbol: "arrow.counterclockwise",
            tooltip: "Reset light match colors",
            action: #selector(resetLightMatchColors(_:))
        )
        configureIconButton(
            resetDarkMatchColorsButton,
            symbol: "arrow.counterclockwise",
            tooltip: "Reset dark match colors",
            action: #selector(resetDarkMatchColors(_:))
        )
    }

    private func makeMatchColorPaletteRow(
        paletteControl: MatchColorPaletteControl,
        resetButton: NSButton
    ) -> NSView {
        let stack = NSStackView(views: [paletteControl, resetButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10

        NSLayoutConstraint.activate([
            resetButton.widthAnchor.constraint(equalToConstant: 28),
            resetButton.heightAnchor.constraint(equalToConstant: 24)
        ])

        return stack
    }

    private func updateMatchColorControls() {
        lightMatchColorPaletteControl.configure(defaults: defaults, isDark: false)
        darkMatchColorPaletteControl.configure(defaults: defaults, isDark: true)
    }

    private func configureGlobalHotKeyButton() {
        configureHotKeyButton(
            changeGlobalHotKeyButton,
            action: #selector(changeGlobalHotKey(_:)),
            tooltip: "Change global search hotkey"
        )
    }

    private func configureGlobalAppSearchHotKeyButton() {
        configureHotKeyButton(
            changeGlobalAppSearchHotKeyButton,
            action: #selector(changeGlobalAppSearchHotKey(_:)),
            tooltip: "Change global app search hotkey"
        )
    }

    private func configureHotKeyButton(_ button: NSButton, action: Selector, tooltip: String) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.toolTip = tooltip
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func makeGlobalHotKeyControl() -> NSView {
        let stack = NSStackView(views: [globalHotKeySwitch, changeGlobalHotKeyButton])
        configureHotKeyControlStack(stack, button: changeGlobalHotKeyButton)
        return stack
    }

    private func makeGlobalAppSearchHotKeyControl() -> NSView {
        let stack = NSStackView(views: [globalAppSearchHotKeySwitch, changeGlobalAppSearchHotKeyButton])
        configureHotKeyControlStack(stack, button: changeGlobalAppSearchHotKeyButton)
        return stack
    }

    private func configureHotKeyControlStack(_ stack: NSStackView, button: NSButton) {
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 116)
        ])
    }

    private func configureFullDiskAccessButtons() {
        configureTextButton(
            openFullDiskAccessSettingsButton,
            title: "Open Full Disk Access Settings",
            symbol: "gearshape",
            action: #selector(openFullDiskAccessSettings(_:))
        )
        configureTextButton(
            recheckFullDiskAccessButton,
            title: "Recheck Access",
            symbol: "arrow.clockwise",
            action: #selector(recheckFullDiskAccess(_:))
        )
    }

    private func configureDiagnosticLogLevelControl() {
        diagnosticLogLevelSegmentedControl.translatesAutoresizingMaskIntoConstraints = false
        diagnosticLogLevelSegmentedControl.target = self
        diagnosticLogLevelSegmentedControl.action = #selector(changeDiagnosticLogLevel(_:))
        diagnosticLogLevelSegmentedControl.setContentHuggingPriority(.required, for: .horizontal)
        diagnosticLogLevelSegmentedControl.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func configureIconButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.title = ""
        button.bezelStyle = .texturedRounded
        button.toolTip = tooltip
        button.target = self
        button.action = action
    }

    private func configureAddButton(_ button: NSButton, tooltip: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: tooltip)
        button.imagePosition = .imageLeading
        button.title = "Add"
        button.bezelStyle = .rounded
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func configureTextButton(_ button: NSButton, title: String, symbol: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.toolTip = title
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func makeSettingsCard(rows: [NSView]) -> NSView {
        let card = makeCard()

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0

        for (index, row) in rows.enumerated() {
            stack.addArrangedSubview(row)
            if index < rows.count - 1 {
                stack.addArrangedSubview(makeSeparator())
            }
        }

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])

        return card
    }

    private func makeIndexSummaryCard() -> NSView {
        makeSettingsCard(rows: [
            makeControlRow(
                title: "Size on disk",
                detail: "Current persisted index package size.",
                control: indexSizeValueLabel
            ),
            makeControlRow(
                title: "Created on",
                detail: "Persisted index package creation timestamp.",
                control: indexCreatedValueLabel
            ),
            makeControlRow(
                title: "Reindex",
                detail: "Rebuild the local index from the folders below.",
                control: reindexButton
            )
        ])
    }

    private func makeFullDiskAccessCard() -> NSView {
        let card = makeCard()

        fullDiskAccessStatusIconView.translatesAutoresizingMaskIntoConstraints = false
        fullDiskAccessStatusIconView.image = NSImage(
            systemSymbolName: "questionmark.circle",
            accessibilityDescription: "Full Disk Access status"
        )

        fullDiskAccessStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        fullDiskAccessStatusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        fullDiskAccessStatusLabel.textColor = .labelColor

        fullDiskAccessExplanationLabel.translatesAutoresizingMaskIntoConstraints = false
        fullDiskAccessExplanationLabel.font = .systemFont(ofSize: 12, weight: .regular)
        fullDiskAccessExplanationLabel.textColor = .secondaryLabelColor
        fullDiskAccessExplanationLabel.lineBreakMode = .byWordWrapping
        fullDiskAccessExplanationLabel.maximumNumberOfLines = 3
        fullDiskAccessExplanationLabel.preferredMaxLayoutWidth = 520
        fullDiskAccessExplanationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fullDiskAccessExplanationLabel.stringValue = "Without Full Disk Access, macOS may prompt when AllTheThings indexes or refreshes protected folders such as Desktop, Documents, Downloads, external drives, and cloud folders."

        let textStack = NSStackView(views: [fullDiskAccessStatusLabel, fullDiskAccessExplanationLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 5
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let buttonStack = NSStackView(views: [openFullDiskAccessSettingsButton, recheckFullDiskAccessButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8

        card.addSubview(fullDiskAccessStatusIconView)
        card.addSubview(textStack)
        card.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            fullDiskAccessStatusIconView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            fullDiskAccessStatusIconView.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            fullDiskAccessStatusIconView.widthAnchor.constraint(equalToConstant: 20),
            fullDiskAccessStatusIconView.heightAnchor.constraint(equalToConstant: 20),

            textStack.leadingAnchor.constraint(equalTo: fullDiskAccessStatusIconView.trailingAnchor, constant: 12),
            textStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            textStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            textStack.widthAnchor.constraint(lessThanOrEqualToConstant: 520),

            buttonStack.topAnchor.constraint(equalTo: textStack.bottomAnchor, constant: 14),
            buttonStack.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
            buttonStack.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -20),
            buttonStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18)
        ])

        return card
    }

    private func makeIndexedFoldersAccessWarningView() -> NSView {
        let warningView = indexedFoldersAccessWarningView
        warningView.translatesAutoresizingMaskIntoConstraints = false
        warningView.isHidden = true

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Indexed folders access warning"
        )
        iconView.contentTintColor = .systemYellow

        indexedFoldersAccessWarningLabel.translatesAutoresizingMaskIntoConstraints = false
        indexedFoldersAccessWarningLabel.font = .systemFont(ofSize: 12, weight: .regular)
        indexedFoldersAccessWarningLabel.textColor = .secondaryLabelColor
        indexedFoldersAccessWarningLabel.lineBreakMode = .byWordWrapping
        indexedFoldersAccessWarningLabel.maximumNumberOfLines = 3

        warningView.addSubview(iconView)
        warningView.addSubview(indexedFoldersAccessWarningLabel)

        let warningLabelBottomConstraint = indexedFoldersAccessWarningLabel.bottomAnchor.constraint(
            equalTo: warningView.bottomAnchor,
            constant: -10
        )
        warningLabelBottomConstraint.priority = .defaultLow

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: warningView.leadingAnchor, constant: 12),
            iconView.topAnchor.constraint(equalTo: warningView.topAnchor, constant: 11),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            indexedFoldersAccessWarningLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            indexedFoldersAccessWarningLabel.topAnchor.constraint(equalTo: warningView.topAnchor, constant: 10),
            indexedFoldersAccessWarningLabel.trailingAnchor.constraint(equalTo: warningView.trailingAnchor, constant: -12),
            warningLabelBottomConstraint
        ])

        return warningView
    }

    private func makeIndexedRootsCard() -> NSView {
        let card = makeCard()

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        configureSettingsTable(
            rootsTableView,
            pasteboardType: Self.indexedRootPasteboardType,
            columnIdentifier: IndexedRootCellView.identifier
        )

        scrollView.documentView = rootsTableView
        let heightConstraint = card.heightAnchor.constraint(equalToConstant: Self.tableCardHeight(
            itemCount: indexedRoots.count,
            maximumVisibleRows: Self.indexedRootsMaximumVisibleRows
        ))
        indexedRootsCardHeightConstraint = heightConstraint

        card.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: card.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            heightConstraint
        ])

        return card
    }

    private func makeAppSearchRootsCard() -> NSView {
        let card = makeCard()

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        configureSettingsTable(
            appSearchRootsTableView,
            pasteboardType: Self.appSearchRootPasteboardType,
            columnIdentifier: IndexedRootCellView.identifier
        )

        scrollView.documentView = appSearchRootsTableView
        let heightConstraint = card.heightAnchor.constraint(equalToConstant: Self.tableCardHeight(
            itemCount: appSearchRoots.count,
            maximumVisibleRows: Self.appSearchRootsMaximumVisibleRows
        ))
        appSearchRootsCardHeightConstraint = heightConstraint

        card.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: card.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            heightConstraint
        ])

        return card
    }

    private func makeExclusionPatternsCard() -> NSView {
        let card = makeCard()

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        configureSettingsTable(
            exclusionsTableView,
            pasteboardType: Self.exclusionPatternPasteboardType,
            columnIdentifier: ExclusionPatternCellView.identifier
        )

        scrollView.documentView = exclusionsTableView
        let heightConstraint = card.heightAnchor.constraint(equalToConstant: Self.tableCardHeight(
            itemCount: exclusionPatterns.count,
            maximumVisibleRows: Self.exclusionPatternsMaximumVisibleRows
        ))
        exclusionPatternsCardHeightConstraint = heightConstraint

        card.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: card.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            heightConstraint
        ])

        return card
    }

    private func configureSettingsTable(
        _ tableView: NSTableView,
        pasteboardType: NSPasteboard.PasteboardType,
        columnIdentifier: NSUserInterfaceItemIdentifier
    ) {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = Self.settingsTableRowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.style = .fullWidth
        tableView.allowsMultipleSelection = false
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([pasteboardType])

        if tableView.tableColumns.isEmpty {
            let column = NSTableColumn(identifier: columnIdentifier)
            column.resizingMask = .autoresizingMask
            tableView.addTableColumn(column)
        }
    }

    private func makeCard() -> NSView {
        ThemedCardView(frame: .zero)
    }

    private func makeControlRow(title: String, detail: String, control: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = AppSettings.appFont(defaults: defaults, sizeDelta: 2, weight: .medium)
        titleLabel.textColor = .labelColor

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = AppSettings.appFont(defaults: defaults)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 2

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4

        row.addSubview(textStack)
        row.addSubview(control)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 74),

            textStack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -24),
            textStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -20),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            row.widthAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])

        return row
    }

    private func makeSeparator() -> NSView {
        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator
        NSLayoutConstraint.activate([
            separator.heightAnchor.constraint(equalToConstant: 1)
        ])
        return separator
    }

    private func renderIndexedRoots() {
        indexedRoots = AppSettings.indexedRoots(defaults: defaults)
        rootsTableView.reloadData()
        updateIndexedFolderCardHeights()
        updateIndexedFoldersAccessWarning()
        updateIndexSummary()
    }

    private func renderAppSearchRoots() {
        appSearchRoots = AppSettings.appSearchRoots(defaults: defaults)
        appSearchRootsTableView.reloadData()
        updateIndexedFolderCardHeights()
    }

    private func renderExclusionPatterns() {
        exclusionPatterns = AppSettings.exclusionPatterns(defaults: defaults)
        exclusionsTableView.reloadData()
        updateIndexedFolderCardHeights()
    }

    private func updateIndexedFolderCardHeights() {
        indexedRootsCardHeightConstraint?.constant = Self.tableCardHeight(
            itemCount: indexedRoots.count,
            maximumVisibleRows: Self.indexedRootsMaximumVisibleRows
        )
        appSearchRootsCardHeightConstraint?.constant = Self.tableCardHeight(
            itemCount: appSearchRoots.count,
            maximumVisibleRows: Self.appSearchRootsMaximumVisibleRows
        )
        exclusionPatternsCardHeightConstraint?.constant = Self.tableCardHeight(
            itemCount: exclusionPatterns.count,
            maximumVisibleRows: Self.exclusionPatternsMaximumVisibleRows
        )
    }

    private func updateIndexSummary() {
        let snapshot = index.currentInsightsSnapshot()
        indexSizeValueLabel.stringValue = byteString(snapshot.storage.indexPackageBytes)
        indexCreatedValueLabel.stringValue = dateTimeString(snapshot.storage.indexPackageCreatedAt)
        reindexButton.isEnabled = AppSettings.indexingSetupCompleted(defaults: defaults) && !indexedRoots.isEmpty
    }

    private func updateIndexedFoldersAccessWarning() {
        let protectedFolders = FullDiskAccessController.protectedDefaultFoldersCovered(by: AppSettings.indexedRoots(defaults: defaults))
        let shouldShow = !protectedFolders.isEmpty && !FullDiskAccessController.currentStatus().isConfirmed

        indexedFoldersAccessWarningView.isHidden = !shouldShow
        indexedFoldersAccessWarningCollapsedHeightConstraint?.isActive = !shouldShow
        indexedRootsCardTopConstraint?.constant = shouldShow ? 10 : 0

        guard shouldShow else { return }

        let folderNames = protectedFolders
            .map(\.lastPathComponent)
            .joined(separator: ", ")
        indexedFoldersAccessWarningLabel.stringValue = "\(folderNames) are indexed, but Full Disk Access is not confirmed. Use the Folder Access card above or remove protected folders from indexing."
    }

    private static func tableCardHeight(itemCount: Int, maximumVisibleRows: Int) -> CGFloat {
        let visibleRows = min(max(itemCount, 1), maximumVisibleRows)
        return CGFloat(visibleRows) * settingsTableRowHeight
    }

    private func byteString(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    private func dateTimeString(_ date: Date?) -> String {
        guard let date else { return "Not created" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === rootsTableView {
            return indexedRoots.isEmpty ? 1 : indexedRoots.count
        }

        if tableView === appSearchRootsTableView {
            return appSearchRoots.isEmpty ? 1 : appSearchRoots.count
        }

        if tableView === exclusionsTableView {
            return exclusionPatterns.isEmpty ? 1 : exclusionPatterns.count
        }

        return 0
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        Self.settingsTableRowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === rootsTableView {
            guard !indexedRoots.isEmpty else {
                let view = EmptyListCellView()
                view.messageLabel.stringValue = "No indexed folders"
                return view
            }

            guard row >= 0, row < indexedRoots.count else { return nil }

            let cell = IndexedRootCellView()
            cell.configure(
                root: indexedRoots[row],
                index: row,
                target: self,
                removeAction: #selector(removeIndexedRoot(_:))
            )
            return cell
        }

        if tableView === appSearchRootsTableView {
            guard !appSearchRoots.isEmpty else {
                let view = EmptyListCellView()
                view.messageLabel.stringValue = "No app search folders"
                return view
            }

            guard row >= 0, row < appSearchRoots.count else { return nil }

            let cell = IndexedRootCellView()
            cell.configure(
                root: appSearchRoots[row],
                index: row,
                target: self,
                removeAction: #selector(removeAppSearchRoot(_:))
            )
            return cell
        }

        if tableView === exclusionsTableView {
            guard !exclusionPatterns.isEmpty else {
                let view = EmptyListCellView()
                view.messageLabel.stringValue = "No excluded paths"
                return view
            }

            guard row >= 0, row < exclusionPatterns.count else { return nil }

            let cell = ExclusionPatternCellView()
            cell.configure(
                pattern: exclusionPatterns[row],
                index: row,
                target: self,
                removeAction: #selector(removeExclusionPattern(_:)),
                fieldAction: #selector(exclusionPatternFieldDidCommit(_:))
            )
            cell.patternField.delegate = self
            return cell
        }

        return nil
    }

    func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> NSPasteboardWriting? {
        let count: Int
        if tableView === rootsTableView {
            count = indexedRoots.count
        } else if tableView === appSearchRootsTableView {
            count = appSearchRoots.count
        } else {
            count = exclusionPatterns.count
        }
        guard row >= 0, row < count else { return nil }

        let item = NSPasteboardItem()
        item.setString(String(row), forType: pasteboardType(for: tableView))
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard info.draggingPasteboard.string(forType: pasteboardType(for: tableView)) != nil else {
            return []
        }

        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row proposedRow: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard
            let sourceString = info.draggingPasteboard.string(forType: pasteboardType(for: tableView)),
            let sourceIndex = Int(sourceString)
        else {
            return false
        }

        if tableView === rootsTableView {
            return moveIndexedRoot(from: sourceIndex, to: proposedRow)
        }

        if tableView === appSearchRootsTableView {
            return moveAppSearchRoot(from: sourceIndex, to: proposedRow)
        }

        if tableView === exclusionsTableView {
            return moveExclusionPattern(from: sourceIndex, to: proposedRow)
        }

        return false
    }

    private func pasteboardType(for tableView: NSTableView) -> NSPasteboard.PasteboardType {
        if tableView === rootsTableView {
            return Self.indexedRootPasteboardType
        }
        if tableView === appSearchRootsTableView {
            return Self.appSearchRootPasteboardType
        }
        return Self.exclusionPatternPasteboardType
    }

    private func moveIndexedRoot(from sourceIndex: Int, to proposedRow: Int) -> Bool {
        guard sourceIndex >= 0, sourceIndex < indexedRoots.count else { return false }

        var destinationIndex = min(max(proposedRow, 0), indexedRoots.count)
        guard destinationIndex != sourceIndex && destinationIndex != sourceIndex + 1 else {
            return false
        }

        let root = indexedRoots.remove(at: sourceIndex)
        if destinationIndex > sourceIndex {
            destinationIndex -= 1
        }
        indexedRoots.insert(root, at: destinationIndex)
        AppSettings.saveIndexedRoots(indexedRoots, defaults: defaults)
        renderIndexedRoots()
        return true
    }

    private func moveAppSearchRoot(from sourceIndex: Int, to proposedRow: Int) -> Bool {
        guard sourceIndex >= 0, sourceIndex < appSearchRoots.count else { return false }

        var destinationIndex = min(max(proposedRow, 0), appSearchRoots.count)
        guard destinationIndex != sourceIndex && destinationIndex != sourceIndex + 1 else {
            return false
        }

        let root = appSearchRoots.remove(at: sourceIndex)
        if destinationIndex > sourceIndex {
            destinationIndex -= 1
        }
        appSearchRoots.insert(root, at: destinationIndex)
        AppSettings.saveAppSearchRoots(appSearchRoots, defaults: defaults)
        renderAppSearchRoots()
        return true
    }

    private func moveExclusionPattern(from sourceIndex: Int, to proposedRow: Int) -> Bool {
        guard sourceIndex >= 0, sourceIndex < exclusionPatterns.count else { return false }

        var destinationIndex = min(max(proposedRow, 0), exclusionPatterns.count)
        guard destinationIndex != sourceIndex && destinationIndex != sourceIndex + 1 else {
            return false
        }

        let pattern = exclusionPatterns.remove(at: sourceIndex)
        if destinationIndex > sourceIndex {
            destinationIndex -= 1
        }
        exclusionPatterns.insert(pattern, at: destinationIndex)
        AppSettings.saveExclusionPatterns(exclusionPatterns, defaults: defaults)
        renderExclusionPatterns()
        return true
    }

    private func updateControls() {
        let themePreference = AppSettings.themePreference(defaults: defaults)
        themeSegmentedControl.selectedSegment = AppThemePreference.allCases.firstIndex(of: themePreference) ?? 0
        updateFontControls()
        updateMatchColorControls()
        let globalHotKeyEnabled = AppSettings.globalSearchHotKeyEnabled(defaults: defaults)
        globalHotKeySwitch.state = globalHotKeyEnabled ? .on : .off
        changeGlobalHotKeyButton.title = AppSettings.globalSearchHotKey(defaults: defaults).displayString
        changeGlobalHotKeyButton.isEnabled = true
        let globalAppSearchHotKeyEnabled = AppSettings.globalAppSearchHotKeyEnabled(defaults: defaults)
        globalAppSearchHotKeySwitch.state = globalAppSearchHotKeyEnabled ? .on : .off
        changeGlobalAppSearchHotKeyButton.title = AppSettings.globalAppSearchHotKey(defaults: defaults).displayString
        changeGlobalAppSearchHotKeyButton.isEnabled = true
        launchAtLoginSwitch.state = LaunchAtLoginController.isEnabled ? .on : .off
        menuBarIconSwitch.state = AppSettings.menuBarIconEnabled(defaults: defaults) ? .on : .off
        highlightSearchTextSwitch.state = defaults.bool(forKey: AppSettings.highlightSearchTextKey) ? .on : .off
        showHiddenFilesSwitch.state = defaults.bool(forKey: AppSettings.showHiddenFilesKey) ? .on : .off
        allowMultipleInstancesSwitch.state = defaults.bool(forKey: AppSettings.allowMultipleInstancesKey) ? .on : .off
        automaticallyCheckForUpdatesSwitch.state = ReleaseUpdater.shared.automaticallyChecksForUpdates ? .on : .off
        diagnosticLogLevelSegmentedControl.selectedSegment = Self.diagnosticDetailLevels.firstIndex(
            of: AppSettings.diagnosticLogLevel(defaults: defaults)
        ) ?? 0
        updateFullDiskAccessStatus()
        updateIndexedFoldersAccessWarning()
    }

    private func updateFullDiskAccessStatus() {
        let status = FullDiskAccessController.currentStatus()
        DiagnosticLogger.shared.log(
            category: "privacy",
            event: "fullDiskAccess.statusChecked",
            fields: [
                "status": .publicString(status.displayTitle)
            ]
        )
        fullDiskAccessStatusLabel.stringValue = "Full Disk Access: \(status.displayTitle)"

        switch status {
        case .confirmed:
            fullDiskAccessStatusIconView.image = NSImage(
                systemSymbolName: "checkmark.circle.fill",
                accessibilityDescription: "Full Disk Access confirmed"
            )
            fullDiskAccessStatusIconView.contentTintColor = .systemGreen
        case .notConfirmed:
            fullDiskAccessStatusIconView.image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: "Full Disk Access not confirmed"
            )
            fullDiskAccessStatusIconView.contentTintColor = .systemYellow
        case .unknown:
            fullDiskAccessStatusIconView.image = NSImage(
                systemSymbolName: "questionmark.circle.fill",
                accessibilityDescription: "Full Disk Access unknown"
            )
            fullDiskAccessStatusIconView.contentTintColor = .secondaryLabelColor
        }
    }

    @objc private func openFullDiskAccessSettings(_ sender: NSButton) {
        DiagnosticLogger.shared.log(category: "privacy", event: "fullDiskAccess.openSettingsFromSettings")
        FullDiskAccessController.openSystemSettings()
    }

    @objc private func recheckFullDiskAccess(_ sender: NSButton) {
        updateFullDiskAccessStatus()
        updateIndexedFoldersAccessWarning()
    }

    @objc private func changeDiagnosticLogLevel(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0, sender.selectedSegment < Self.diagnosticDetailLevels.count else { return }

        AppSettings.saveDiagnosticLogLevel(Self.diagnosticDetailLevels[sender.selectedSegment], defaults: defaults)
    }

    @objc private func changeThemePreference(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0, sender.selectedSegment < AppThemePreference.allCases.count else { return }

        AppSettings.saveThemePreference(AppThemePreference.allCases[sender.selectedSegment], defaults: defaults)
    }

    @objc private func changeAppFontFamily(_ sender: NSPopUpButton) {
        let familyName = sender.selectedItem?.representedObject as? String
        AppSettings.saveAppFontFamilyName(familyName, defaults: defaults)
        updateFontControls()
    }

    @objc private func changeAppFontSize(_ sender: NSStepper) {
        AppSettings.saveAppFontSize(CGFloat(sender.doubleValue), defaults: defaults)
        updateFontControls()
    }

    @objc private func resetAppFont(_ sender: NSButton) {
        AppSettings.resetAppFont(defaults: defaults)
        updateFontControls()
    }

    @objc private func resetLightMatchColors(_ sender: NSButton) {
        AppSettings.resetMatchColors(isDark: false, defaults: defaults)
        updateMatchColorControls()
    }

    @objc private func resetDarkMatchColors(_ sender: NSButton) {
        AppSettings.resetMatchColors(isDark: true, defaults: defaults)
        updateMatchColorControls()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSSwitch) {
        do {
            try LaunchAtLoginController.setEnabled(sender.state == .on)
            if LaunchAtLoginController.requiresApproval {
                presentLaunchAtLoginApprovalRequired()
            }
        } catch {
            presentError("Could not update launch at login.", informativeText: error.localizedDescription)
        }

        updateControls()
    }

    private func presentLaunchAtLoginApprovalRequired() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Approve launch at login"
        alert.informativeText = "macOS needs approval before AllTheThings can launch at login."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "OK")

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            LaunchAtLoginController.openSystemSettings()
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    @objc private func toggleGlobalHotKey(_ sender: NSSwitch) {
        let hotKey = AppSettings.globalSearchHotKey(defaults: defaults)
        guard sender.state == .on else {
            saveGlobalHotKey(enabled: false, hotKey: hotKey)
            return
        }

        confirmGlobalHotKeyChange(hotKey) { [weak self] didConfirm in
            guard let self else { return }
            if didConfirm {
                self.saveGlobalHotKey(enabled: true, hotKey: hotKey)
            } else {
                self.updateControls()
            }
        }
    }

    @objc private func changeGlobalHotKey(_ sender: NSButton) {
        let recorder = HotKeyRecorderView()
        let alert = NSAlert()
        alert.messageText = "Change global search hotkey"
        alert.informativeText = "Press a shortcut with a non-modifier key and at least one modifier."
        alert.accessoryView = recorder
        let saveButton = alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        saveButton.isEnabled = false
        alert.window.initialFirstResponder = recorder

        recorder.onChange = { hotKey in
            saveButton.isEnabled = hotKey != nil
        }
        recorder.onCancel = { [weak alert] in
            guard let window = alert?.window else { return }
            if let sheetParent = window.sheetParent {
                sheetParent.endSheet(window, returnCode: .cancel)
            } else {
                NSApp.stopModal(withCode: .cancel)
                window.orderOut(nil)
            }
        }

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard
                response == .alertFirstButtonReturn,
                let self,
                let hotKey = recorder.recordedHotKey
            else {
                self?.updateControls()
                return
            }

            guard
                !AppSettings.globalSearchHotKeyEnabled(defaults: self.defaults)
                    || hotKey != AppSettings.globalSearchHotKey(defaults: self.defaults)
            else {
                self.updateControls()
                return
            }

            self.confirmGlobalHotKeyChange(hotKey) { [weak self] didConfirm in
                guard let self else { return }
                if didConfirm {
                    self.saveGlobalHotKey(enabled: true, hotKey: hotKey)
                } else {
                    self.updateControls()
                }
            }
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
            DispatchQueue.main.async {
                alert.window.makeFirstResponder(recorder)
            }
        } else {
            DispatchQueue.main.async {
                alert.window.makeFirstResponder(recorder)
            }
            completion(alert.runModal())
        }
    }

    private func confirmGlobalHotKeyChange(_ hotKey: GlobalHotKey, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Use \(hotKey.displayString) as the global search hotkey?"
        alert.informativeText = "AllTheThings will claim this shortcut system-wide while it is running. If another app or macOS feature already uses this shortcut, choose a different one instead."
        alert.addButton(withTitle: "Use Shortcut")
        alert.addButton(withTitle: "Cancel")

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .alertFirstButtonReturn)
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    private func saveGlobalHotKey(enabled: Bool, hotKey: GlobalHotKey) {
        do {
            if let appDelegate = NSApp.delegate as? AppDelegate {
                try appDelegate.saveGlobalSearchHotKey(enabled: enabled, hotKey: hotKey)
            } else {
                AppSettings.saveGlobalSearchHotKey(enabled: enabled, hotKey: hotKey, defaults: defaults)
            }
        } catch {
            presentError("Could not register global search hotkey.", informativeText: error.localizedDescription)
        }

        updateControls()
    }

    @objc private func toggleGlobalAppSearchHotKey(_ sender: NSSwitch) {
        let hotKey = AppSettings.globalAppSearchHotKey(defaults: defaults)
        guard sender.state == .on else {
            saveGlobalAppSearchHotKey(enabled: false, hotKey: hotKey)
            return
        }

        confirmGlobalAppSearchHotKeyChange(hotKey) { [weak self] didConfirm in
            guard let self else { return }
            if didConfirm {
                self.saveGlobalAppSearchHotKey(enabled: true, hotKey: hotKey)
            } else {
                self.updateControls()
            }
        }
    }

    @objc private func changeGlobalAppSearchHotKey(_ sender: NSButton) {
        let recorder = HotKeyRecorderView()
        let alert = NSAlert()
        alert.messageText = "Change global app search hotkey"
        alert.informativeText = "Press a shortcut with a non-modifier key and at least one modifier."
        alert.accessoryView = recorder
        let saveButton = alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        saveButton.isEnabled = false
        alert.window.initialFirstResponder = recorder

        recorder.onChange = { hotKey in
            saveButton.isEnabled = hotKey != nil
        }
        recorder.onCancel = { [weak alert] in
            guard let window = alert?.window else { return }
            if let sheetParent = window.sheetParent {
                sheetParent.endSheet(window, returnCode: .cancel)
            } else {
                NSApp.stopModal(withCode: .cancel)
                window.orderOut(nil)
            }
        }

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard
                response == .alertFirstButtonReturn,
                let self,
                let hotKey = recorder.recordedHotKey
            else {
                self?.updateControls()
                return
            }

            guard
                !AppSettings.globalAppSearchHotKeyEnabled(defaults: self.defaults)
                    || hotKey != AppSettings.globalAppSearchHotKey(defaults: self.defaults)
            else {
                self.updateControls()
                return
            }

            self.confirmGlobalAppSearchHotKeyChange(hotKey) { [weak self] didConfirm in
                guard let self else { return }
                if didConfirm {
                    self.saveGlobalAppSearchHotKey(enabled: true, hotKey: hotKey)
                } else {
                    self.updateControls()
                }
            }
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
            DispatchQueue.main.async {
                alert.window.makeFirstResponder(recorder)
            }
        } else {
            DispatchQueue.main.async {
                alert.window.makeFirstResponder(recorder)
            }
            completion(alert.runModal())
        }
    }

    private func confirmGlobalAppSearchHotKeyChange(_ hotKey: GlobalHotKey, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Use \(hotKey.displayString) as the global app search hotkey?"
        alert.informativeText = "AllTheThings will claim this shortcut system-wide while it is running and use it to open search with app: ready. If another app or macOS feature already uses this shortcut, choose a different one instead."
        alert.addButton(withTitle: "Use Shortcut")
        alert.addButton(withTitle: "Cancel")

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .alertFirstButtonReturn)
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    private func saveGlobalAppSearchHotKey(enabled: Bool, hotKey: GlobalHotKey) {
        do {
            if let appDelegate = NSApp.delegate as? AppDelegate {
                try appDelegate.saveGlobalAppSearchHotKey(enabled: enabled, hotKey: hotKey)
            } else {
                AppSettings.saveGlobalAppSearchHotKey(enabled: enabled, hotKey: hotKey, defaults: defaults)
            }
        } catch {
            presentError("Could not register global app search hotkey.", informativeText: error.localizedDescription)
        }

        updateControls()
    }

    private func presentError(_ message: String, informativeText: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = informativeText

        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc private func toggleHighlightSearchText(_ sender: NSSwitch) {
        defaults.set(sender.state == .on, forKey: AppSettings.highlightSearchTextKey)
        defaults.synchronize()
    }

    @objc private func toggleMenuBarIcon(_ sender: NSSwitch) {
        AppSettings.saveMenuBarIconEnabled(sender.state == .on, defaults: defaults)
    }

    @objc private func toggleShowHiddenFiles(_ sender: NSSwitch) {
        defaults.set(sender.state == .on, forKey: AppSettings.showHiddenFilesKey)
        defaults.synchronize()
    }

    @objc private func toggleAllowMultipleInstances(_ sender: NSSwitch) {
        defaults.set(sender.state == .on, forKey: AppSettings.allowMultipleInstancesKey)
        defaults.synchronize()
    }

    @objc private func toggleAutomaticallyCheckForUpdates(_ sender: NSSwitch) {
        ReleaseUpdater.shared.automaticallyChecksForUpdates = sender.state == .on
        defaults.synchronize()
    }

    @objc private func addIndexedRoot(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self else { return }

            var roots = AppSettings.indexedRoots(defaults: self.defaults)
            var existing = Set(roots.map { $0.standardizedFileURL.path })

            for url in panel.urls.map(\.standardizedFileURL) where existing.insert(url.path).inserted {
                roots.append(url)
            }

            AppSettings.saveIndexedRoots(roots, defaults: self.defaults)
            self.renderIndexedRoots()
        }

        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    @objc private func reindexIndexedFolders(_ sender: NSButton) {
        guard AppSettings.indexingSetupCompleted(defaults: defaults), !indexedRoots.isEmpty else {
            updateIndexSummary()
            return
        }

        reindexHandler()
        updateIndexSummary()
    }

    @objc private func removeIndexedRoot(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < indexedRoots.count else { return }

        indexedRoots.remove(at: sender.tag)
        AppSettings.saveIndexedRoots(indexedRoots, defaults: defaults)
        renderIndexedRoots()
    }

    @objc private func resetIndexedRoots(_ sender: NSButton) {
        AppSettings.resetIndexedRoots(defaults: defaults)
        renderIndexedRoots()
    }

    @objc private func indexedRootsDidChange(_ notification: Notification) {
        renderIndexedRoots()
    }

    @objc private func addAppSearchRoot(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self else { return }

            var roots = AppSettings.appSearchRoots(defaults: self.defaults)
            var existing = Set(roots.map { $0.standardizedFileURL.path })

            for url in panel.urls.map(\.standardizedFileURL) where existing.insert(url.path).inserted {
                roots.append(url)
            }

            AppSettings.saveAppSearchRoots(roots, defaults: self.defaults)
            self.renderAppSearchRoots()
        }

        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    @objc private func removeAppSearchRoot(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < appSearchRoots.count else { return }

        appSearchRoots.remove(at: sender.tag)
        AppSettings.saveAppSearchRoots(appSearchRoots, defaults: defaults)
        renderAppSearchRoots()
    }

    @objc private func resetAppSearchRoots(_ sender: NSButton) {
        AppSettings.resetAppSearchRoots(defaults: defaults)
        renderAppSearchRoots()
    }

    @objc private func appSearchRootsDidChange(_ notification: Notification) {
        renderAppSearchRoots()
    }

    @objc private func addExclusionPattern(_ sender: NSButton) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "**/.cache/"
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        let alert = NSAlert()
        alert.messageText = "Add excluded path"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let newPatterns = self.normalizedExclusionPatterns([field.stringValue])
            guard let newPattern = newPatterns.first else { return }

            var patterns = AppSettings.exclusionPatterns(defaults: self.defaults)
            guard !patterns.contains(newPattern) else { return }

            patterns.append(newPattern)
            AppSettings.saveExclusionPatterns(patterns, defaults: self.defaults)
            self.renderExclusionPatterns()
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    @objc private func removeExclusionPattern(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < exclusionPatterns.count else { return }

        exclusionPatterns.remove(at: sender.tag)
        AppSettings.saveExclusionPatterns(exclusionPatterns, defaults: defaults)
        renderExclusionPatterns()
    }

    @objc private func resetExclusionPatterns(_ sender: NSButton) {
        AppSettings.resetExclusionPatterns(defaults: defaults)
        renderExclusionPatterns()
    }

    @objc private func exclusionPatternFieldDidCommit(_ sender: NSTextField) {
        saveExclusionPattern(sender)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard
            let field = obj.object as? NSTextField,
            field.identifier == Self.exclusionPatternFieldIdentifier
        else {
            return
        }

        saveExclusionPattern(field)
    }

    private func saveExclusionPatternsFromRows() {
        let patterns = normalizedExclusionPatterns(exclusionPatterns)
        guard patterns != AppSettings.exclusionPatterns(defaults: defaults) else {
            renderExclusionPatterns()
            return
        }

        AppSettings.saveExclusionPatterns(patterns, defaults: defaults)
        renderExclusionPatterns()
    }

    private func saveExclusionPattern(_ field: NSTextField) {
        guard field.tag >= 0, field.tag < exclusionPatterns.count else { return }

        exclusionPatterns[field.tag] = field.stringValue
        saveExclusionPatternsFromRows()
    }

    private func normalizedExclusionPatterns(_ rawPatterns: [String]) -> [String] {
        var seen = Set<String>()
        var patterns: [String] = []

        for rawPattern in rawPatterns {
            let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty, seen.insert(pattern).inserted else { continue }
            patterns.append(pattern)
        }

        return patterns
    }

    @objc private func showExclusionPatternHelp(_ sender: NSButton) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 276, height: 168)

        let contentViewController = NSViewController()
        let contentView = NSView(frame: NSRect(origin: .zero, size: popover.contentSize))
        contentView.wantsLayer = true

        let titleLabel = NSTextField(labelWithString: "Ignore patterns")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .left

        let examples = [
            ("folder/", "folder anywhere"),
            ("*.tmp", "filename match"),
            ("path/*.log", "relative path"),
            ("**", "spans folders"),
            ("!pattern", "re-include match"),
            ("#", "comment, \\# literal")
        ]

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.addArrangedSubview(titleLabel)
        stack.setCustomSpacing(9, after: titleLabel)

        for (pattern, description) in examples {
            let row = NSStackView()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 10

            let patternLabel = NSTextField(labelWithString: pattern)
            patternLabel.translatesAutoresizingMaskIntoConstraints = false
            patternLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            patternLabel.textColor = .labelColor
            patternLabel.lineBreakMode = .byTruncatingTail

            let descriptionLabel = NSTextField(labelWithString: description)
            descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
            descriptionLabel.font = .systemFont(ofSize: 11, weight: .regular)
            descriptionLabel.textColor = .secondaryLabelColor
            descriptionLabel.lineBreakMode = .byTruncatingTail
            descriptionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            row.addArrangedSubview(patternLabel)
            row.addArrangedSubview(descriptionLabel)
            stack.addArrangedSubview(row)

            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalToConstant: 248),
                patternLabel.widthAnchor.constraint(equalToConstant: 86)
            ])
        }

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 13),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -13)
        ])

        contentViewController.view = contentView
        popover.contentViewController = contentViewController
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func exclusionPatternsDidChange(_ notification: Notification) {
        renderExclusionPatterns()
    }

    @objc private nonisolated func userDefaultsDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.updateControls()
        }
    }
}
