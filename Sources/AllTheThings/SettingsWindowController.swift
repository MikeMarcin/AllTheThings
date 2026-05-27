import AppKit
import ATTCore
import Carbon.HIToolbox

@MainActor
final class SettingsWindowController: NSWindowController {
    init(defaults: UserDefaults = .standard) {
        let contentSize = NSSize(width: 780, height: 640)
        let viewController = SettingsViewController(defaults: defaults)
        viewController.preferredContentSize = contentSize
        let window = NSWindow(
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
}

private enum SettingsSection {
    case general
    case indexedFolders

    var title: String {
        switch self {
        case .general: "General"
        case .indexedFolders: "Indexed Folders"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .indexedFolders: "folder"
        }
    }
}

@MainActor
private final class SettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let defaults: UserDefaults
    private let contentContainer = NSView()
    private let generalSidebarRow = SidebarRow(section: .general)
    private let indexedFoldersSidebarRow = SidebarRow(section: .indexedFolders)
    private let themeSegmentedControl = NSSegmentedControl(
        labels: AppThemePreference.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let globalHotKeySwitch = NSSwitch()
    private let changeGlobalHotKeyButton = NSButton()
    private let launchAtLoginSwitch = NSSwitch()
    private let menuBarIconSwitch = NSSwitch()
    private let highlightSearchTextSwitch = NSSwitch()
    private let showHiddenFilesSwitch = NSSwitch()
    private let allowMultipleInstancesSwitch = NSSwitch()
    private let automaticallyCheckForUpdatesSwitch = NSSwitch()
    private let rootsTableView = NSTableView()
    private let addRootButton = NSButton()
    private let resetRootsButton = NSButton()
    private let exclusionsTableView = NSTableView()
    private let addExclusionButton = NSButton()
    private let resetExclusionsButton = NSButton()
    private let exclusionHelpButton = NSButton()
    private var pageViews: [SettingsSection: NSView] = [:]
    private var selectedSection = SettingsSection.general
    private var indexedRoots: [URL] = []
    private var exclusionPatterns: [String] = []
    private var indexedRootsCardHeightConstraint: NSLayoutConstraint?
    private var exclusionPatternsCardHeightConstraint: NSLayoutConstraint?

    private static let exclusionPatternFieldIdentifier = NSUserInterfaceItemIdentifier("exclusionPatternField")
    private static let indexedRootPasteboardType = NSPasteboard.PasteboardType("com.allthethings.settings.indexed-root-row")
    private static let exclusionPatternPasteboardType = NSPasteboard.PasteboardType("com.allthethings.settings.exclusion-pattern-row")
    private static let settingsTableRowHeight: CGFloat = 42
    private static let indexedRootsMaximumVisibleRows = 8
    private static let exclusionPatternsMaximumVisibleRows = 10

    init(defaults: UserDefaults) {
        self.defaults = defaults
        AppSettings.registerDefaults(defaults)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = ThemedBackgroundView(frame: NSRect(x: 0, y: 0, width: 780, height: 640))
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

        let stack = NSStackView(views: [generalSidebarRow, indexedFoldersSidebarRow])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 6

        for row in [generalSidebarRow, indexedFoldersSidebarRow] {
            row.target = self
            row.action = #selector(selectSidebarRow(_:))
        }

        sidebar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: sidebar.safeAreaLayoutGuide.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            generalSidebarRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            indexedFoldersSidebarRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        return sidebar
    }

    @objc private func selectSidebarRow(_ sender: SidebarRow) {
        selectSection(sender.section)
    }

    private func selectSection(_ section: SettingsSection) {
        selectedSection = section
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
            renderExclusionPatterns()
        }
    }

    private func pageView(for section: SettingsSection) -> NSView {
        if let page = pageViews[section] {
            return page
        }

        let page: NSView
        switch section {
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

    private func makeGeneralPage() -> NSView {
        let (scrollView, contentView) = makePageScrollView()

        let sectionLabel = makeSectionLabel("Application")

        configureThemeControl()
        configureSwitch(globalHotKeySwitch, action: #selector(toggleGlobalHotKey(_:)))
        configureGlobalHotKeyButton()
        configureSwitch(launchAtLoginSwitch, action: #selector(toggleLaunchAtLogin(_:)))
        configureSwitch(menuBarIconSwitch, action: #selector(toggleMenuBarIcon(_:)))
        configureSwitch(highlightSearchTextSwitch, action: #selector(toggleHighlightSearchText(_:)))
        configureSwitch(showHiddenFilesSwitch, action: #selector(toggleShowHiddenFiles(_:)))
        configureSwitch(allowMultipleInstancesSwitch, action: #selector(toggleAllowMultipleInstances(_:)))
        configureSwitch(automaticallyCheckForUpdatesSwitch, action: #selector(toggleAutomaticallyCheckForUpdates(_:)))

        let settingsCard = makeSettingsCard(rows: [
            makeControlRow(
                title: "Theme",
                detail: "Choose the app appearance.",
                control: themeSegmentedControl
            ),
            makeControlRow(
                title: "Global search hotkey",
                detail: "Focus the search window from any app.",
                control: makeGlobalHotKeyControl()
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

        contentView.addSubview(sectionLabel)
        contentView.addSubview(settingsCard)

        NSLayoutConstraint.activate([
            sectionLabel.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor, constant: 26),
            sectionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 36),
            sectionLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -36),

            settingsCard.topAnchor.constraint(equalTo: sectionLabel.bottomAnchor, constant: 12),
            settingsCard.leadingAnchor.constraint(equalTo: sectionLabel.leadingAnchor),
            settingsCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -36),
            settingsCard.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
        ])

        return scrollView
    }

    private func makeIndexedFoldersPage() -> NSView {
        let (scrollView, contentView) = makePageScrollView()

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

        let rootsCard = makeIndexedRootsCard()

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

        contentView.addSubview(rootsHeader)
        contentView.addSubview(rootsCard)
        contentView.addSubview(exclusionsHeader)
        contentView.addSubview(exclusionsCard)

        NSLayoutConstraint.activate([
            rootsHeader.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor, constant: 26),
            rootsHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 36),
            rootsHeader.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -36),
            resetRootsButton.widthAnchor.constraint(equalToConstant: 28),
            resetRootsButton.heightAnchor.constraint(equalToConstant: 24),
            addRootButton.widthAnchor.constraint(equalToConstant: 74),
            addRootButton.heightAnchor.constraint(equalToConstant: 30),

            rootsCard.topAnchor.constraint(equalTo: rootsHeader.bottomAnchor, constant: 10),
            rootsCard.leadingAnchor.constraint(equalTo: rootsHeader.leadingAnchor),
            rootsCard.trailingAnchor.constraint(equalTo: rootsHeader.trailingAnchor),

            exclusionsHeader.topAnchor.constraint(equalTo: rootsCard.bottomAnchor, constant: 28),
            exclusionsHeader.leadingAnchor.constraint(equalTo: rootsCard.leadingAnchor),
            exclusionsHeader.trailingAnchor.constraint(equalTo: rootsCard.trailingAnchor),
            exclusionHelpButton.widthAnchor.constraint(equalToConstant: 20),
            exclusionHelpButton.heightAnchor.constraint(equalToConstant: 20),
            resetExclusionsButton.widthAnchor.constraint(equalToConstant: 28),
            resetExclusionsButton.heightAnchor.constraint(equalToConstant: 24),
            addExclusionButton.widthAnchor.constraint(equalToConstant: 74),
            addExclusionButton.heightAnchor.constraint(equalToConstant: 30),

            exclusionsCard.topAnchor.constraint(equalTo: exclusionsHeader.bottomAnchor, constant: 10),
            exclusionsCard.leadingAnchor.constraint(equalTo: rootsCard.leadingAnchor),
            exclusionsCard.trailingAnchor.constraint(equalTo: rootsCard.trailingAnchor),
            exclusionsCard.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24),
            contentBottomConstraint
        ])

        return scrollView
    }

    private func makeSectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func configureSwitch(_ control: NSSwitch, action: Selector) {
        control.translatesAutoresizingMaskIntoConstraints = false
        control.target = self
        control.action = action
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

    private func configureGlobalHotKeyButton() {
        changeGlobalHotKeyButton.translatesAutoresizingMaskIntoConstraints = false
        changeGlobalHotKeyButton.bezelStyle = .rounded
        changeGlobalHotKeyButton.target = self
        changeGlobalHotKeyButton.action = #selector(changeGlobalHotKey(_:))
        changeGlobalHotKeyButton.toolTip = "Change global search hotkey"
        changeGlobalHotKeyButton.setContentHuggingPriority(.required, for: .horizontal)
        changeGlobalHotKeyButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func makeGlobalHotKeyControl() -> NSView {
        let stack = NSStackView(views: [globalHotKeySwitch, changeGlobalHotKeyButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10

        NSLayoutConstraint.activate([
            changeGlobalHotKeyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 116)
        ])

        return stack
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
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .labelColor

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
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
        exclusionPatternsCardHeightConstraint?.constant = Self.tableCardHeight(
            itemCount: exclusionPatterns.count,
            maximumVisibleRows: Self.exclusionPatternsMaximumVisibleRows
        )
    }

    private static func tableCardHeight(itemCount: Int, maximumVisibleRows: Int) -> CGFloat {
        let visibleRows = min(max(itemCount, 1), maximumVisibleRows)
        return CGFloat(visibleRows) * settingsTableRowHeight
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === rootsTableView {
            return indexedRoots.isEmpty ? 1 : indexedRoots.count
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
        let count = tableView === rootsTableView ? indexedRoots.count : exclusionPatterns.count
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

        if tableView === exclusionsTableView {
            return moveExclusionPattern(from: sourceIndex, to: proposedRow)
        }

        return false
    }

    private func pasteboardType(for tableView: NSTableView) -> NSPasteboard.PasteboardType {
        tableView === rootsTableView ? Self.indexedRootPasteboardType : Self.exclusionPatternPasteboardType
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
        let globalHotKeyEnabled = AppSettings.globalSearchHotKeyEnabled(defaults: defaults)
        globalHotKeySwitch.state = globalHotKeyEnabled ? .on : .off
        changeGlobalHotKeyButton.title = AppSettings.globalSearchHotKey(defaults: defaults).displayString
        changeGlobalHotKeyButton.isEnabled = true
        launchAtLoginSwitch.state = LaunchAtLoginController.isEnabled ? .on : .off
        menuBarIconSwitch.state = AppSettings.menuBarIconEnabled(defaults: defaults) ? .on : .off
        highlightSearchTextSwitch.state = defaults.bool(forKey: AppSettings.highlightSearchTextKey) ? .on : .off
        showHiddenFilesSwitch.state = defaults.bool(forKey: AppSettings.showHiddenFilesKey) ? .on : .off
        allowMultipleInstancesSwitch.state = defaults.bool(forKey: AppSettings.allowMultipleInstancesKey) ? .on : .off
        automaticallyCheckForUpdatesSwitch.state = ReleaseUpdater.shared.automaticallyChecksForUpdates ? .on : .off
    }

    @objc private func changeThemePreference(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0, sender.selectedSegment < AppThemePreference.allCases.count else { return }

        AppSettings.saveThemePreference(AppThemePreference.allCases[sender.selectedSegment], defaults: defaults)
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
        popover.contentSize = NSSize(width: 300, height: 176)

        let contentViewController = NSViewController()
        let contentView = NSView(frame: NSRect(origin: .zero, size: popover.contentSize))
        contentView.wantsLayer = true

        let titleLabel = NSTextField(labelWithString: "Ignore pattern syntax")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor

        let examples = [
            "folder/ excludes a folder anywhere",
            "*.tmp matches names",
            "path/*.log matches relative paths",
            "** spans folders",
            "!pattern re-includes earlier matches",
            "# comments, \\# literal #"
        ]

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.addArrangedSubview(titleLabel)

        for example in examples {
            let label = NSTextField(wrappingLabelWithString: example)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: 12, weight: .regular)
            label.textColor = .secondaryLabelColor
            stack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12)
        ])

        contentViewController.view = contentView
        popover.contentViewController = contentViewController
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func exclusionPatternsDidChange(_ notification: Notification) {
        renderExclusionPatterns()
    }

    @objc private func userDefaultsDidChange(_ notification: Notification) {
        updateControls()
    }
}

@MainActor
private final class HotKeyRecorderView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Press shortcut")
    private let detailLabel = NSTextField(labelWithString: "Escape cancels")
    private(set) var recordedHotKey: GlobalHotKey?
    var onChange: ((GlobalHotKey?) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 74))

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.textColor = .labelColor

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.alignment = .center
        detailLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [titleLabel, detailLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 5

        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 320),
            heightAnchor.constraint(equalToConstant: 74),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel?()
            return
        }

        guard let hotKey = GlobalHotKey(event: event) else {
            recordedHotKey = nil
            titleLabel.stringValue = "Invalid shortcut"
            titleLabel.textColor = .systemRed
            detailLabel.stringValue = "Use a non-modifier key with a modifier"
            onChange?(nil)
            return
        }

        recordedHotKey = hotKey
        titleLabel.stringValue = hotKey.displayString
        titleLabel.textColor = .labelColor
        detailLabel.stringValue = "Ready to save"
        onChange?(hotKey)
    }
}

@MainActor
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class EmptyListCellView: NSTableCellView {
    let messageLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = .systemFont(ofSize: 12, weight: .regular)
        messageLabel.textColor = .secondaryLabelColor

        addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class IndexedRootCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("IndexedRootCell")

    private let dragHandleView = NSImageView()
    private let iconView = NSImageView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let removeButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        identifier = Self.identifier

        dragHandleView.translatesAutoresizingMaskIntoConstraints = false
        dragHandleView.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Drag indexed folder")
        dragHandleView.contentTintColor = .tertiaryLabelColor

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Indexed folder")
        iconView.contentTintColor = .secondaryLabelColor

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = .systemFont(ofSize: 12, weight: .regular)
        pathLabel.textColor = .labelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle

        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove indexed folder")
        removeButton.title = ""
        removeButton.isBordered = false
        removeButton.contentTintColor = .secondaryLabelColor
        removeButton.toolTip = "Remove indexed folder"

        for subview in [dragHandleView, iconView, pathLabel, removeButton] {
            addSubview(subview)
        }

        NSLayoutConstraint.activate([
            dragHandleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dragHandleView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dragHandleView.widthAnchor.constraint(equalToConstant: 14),
            dragHandleView.heightAnchor.constraint(equalToConstant: 14),

            iconView.leadingAnchor.constraint(equalTo: dragHandleView.trailingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            pathLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            pathLabel.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -14),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 22),
            removeButton.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(root: URL, index: Int, target: AnyObject, removeAction: Selector) {
        pathLabel.stringValue = AppSettings.displayPath(root)
        removeButton.tag = index
        removeButton.target = target
        removeButton.action = removeAction
    }
}

@MainActor
private final class ExclusionPatternCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ExclusionPatternCell")

    let patternField = NSTextField(string: "")
    private let dragHandleView = NSImageView()
    private let removeButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        identifier = Self.identifier

        dragHandleView.translatesAutoresizingMaskIntoConstraints = false
        dragHandleView.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Drag excluded path")
        dragHandleView.contentTintColor = .tertiaryLabelColor

        patternField.translatesAutoresizingMaskIntoConstraints = false
        patternField.identifier = NSUserInterfaceItemIdentifier("exclusionPatternField")
        patternField.placeholderString = "**/.cache/"
        patternField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        patternField.textColor = .labelColor
        patternField.bezelStyle = .roundedBezel
        patternField.isBordered = true
        patternField.drawsBackground = true

        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove excluded path")
        removeButton.title = ""
        removeButton.isBordered = false
        removeButton.contentTintColor = .secondaryLabelColor
        removeButton.toolTip = "Remove excluded path"

        for subview in [dragHandleView, patternField, removeButton] {
            addSubview(subview)
        }

        NSLayoutConstraint.activate([
            dragHandleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dragHandleView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dragHandleView.widthAnchor.constraint(equalToConstant: 14),
            dragHandleView.heightAnchor.constraint(equalToConstant: 14),

            patternField.leadingAnchor.constraint(equalTo: dragHandleView.trailingAnchor, constant: 12),
            patternField.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -14),
            patternField.centerYAnchor.constraint(equalTo: centerYAnchor),

            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 22),
            removeButton.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        pattern: String,
        index: Int,
        target: AnyObject,
        removeAction: Selector,
        fieldAction: Selector
    ) {
        patternField.stringValue = pattern
        patternField.tag = index
        patternField.target = target
        patternField.action = fieldAction

        removeButton.tag = index
        removeButton.target = target
        removeButton.action = removeAction
    }
}

@MainActor
private final class SidebarRow: NSControl {
    let section: SettingsSection
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    var isSelected = false {
        didSet {
            updateSelectionBackground()
        }
    }

    init(section: SettingsSection) {
        self.section = section
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        updateSelectionBackground()

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: section.symbolName, accessibilityDescription: section.title)
        iconView.contentTintColor = .labelColor

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = section.title
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .labelColor

        addSubview(iconView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelectionBackground()
    }

    private func updateSelectionBackground() {
        layer?.backgroundColor = isSelected
            ? AppTheme.resolvedCGColor(NSColor.selectedContentBackgroundColor.withAlphaComponent(0.28), for: self)
            : AppTheme.resolvedCGColor(.clear, for: self)
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }
}
