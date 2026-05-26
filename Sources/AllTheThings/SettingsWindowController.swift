import AppKit
import ATTCore

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

    private static let exclusionPatternFieldIdentifier = NSUserInterfaceItemIdentifier("exclusionPatternField")
    private static let indexedRootPasteboardType = NSPasteboard.PasteboardType("com.allthethings.settings.indexed-root-row")
    private static let exclusionPatternPasteboardType = NSPasteboard.PasteboardType("com.allthethings.settings.exclusion-pattern-row")

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
        view = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 640))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        buildInterface()
        updateSwitches()
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

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentView

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        return (scrollView, contentView)
    }

    private func makeGeneralPage() -> NSView {
        let (scrollView, contentView) = makePageScrollView()

        let titleLabel = makeTitleLabel("General")
        let sectionLabel = makeSectionLabel("Application")

        configureSwitch(highlightSearchTextSwitch, action: #selector(toggleHighlightSearchText(_:)))
        configureSwitch(showHiddenFilesSwitch, action: #selector(toggleShowHiddenFiles(_:)))
        configureSwitch(allowMultipleInstancesSwitch, action: #selector(toggleAllowMultipleInstances(_:)))
        configureSwitch(automaticallyCheckForUpdatesSwitch, action: #selector(toggleAutomaticallyCheckForUpdates(_:)))

        let settingsCard = makeSettingsCard(rows: [
            makeSwitchRow(
                title: "Highlight search text",
                detail: "Highlight matching text in file names while searching.",
                control: highlightSearchTextSwitch
            ),
            makeSwitchRow(
                title: "Show hidden files",
                detail: "Include dotfiles and hidden items in search results.",
                control: showHiddenFilesSwitch
            ),
            makeSwitchRow(
                title: "Allow multiple instances",
                detail: "Open a new app instance instead of activating the existing one.",
                control: allowMultipleInstancesSwitch
            ),
            makeSwitchRow(
                title: "Automatically check for updates",
                detail: "Look for new GitHub releases in the background.",
                control: automaticallyCheckForUpdatesSwitch
            )
        ])

        contentView.addSubview(titleLabel)
        contentView.addSubview(sectionLabel)
        contentView.addSubview(settingsCard)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor, constant: 58),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 52),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -52),

            sectionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 42),
            sectionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            sectionLabel.trailingAnchor.constraint(lessThanOrEqualTo: titleLabel.trailingAnchor),

            settingsCard.topAnchor.constraint(equalTo: sectionLabel.bottomAnchor, constant: 12),
            settingsCard.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            settingsCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -52),
            settingsCard.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -32)
        ])

        return scrollView
    }

    private func makeIndexedFoldersPage() -> NSView {
        let (scrollView, contentView) = makePageScrollView()

        let titleLabel = makeTitleLabel("Indexed Folders")
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
        addRootButton.translatesAutoresizingMaskIntoConstraints = false
        addRootButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add indexed folder")
        addRootButton.title = ""
        addRootButton.bezelStyle = .texturedRounded
        addRootButton.toolTip = "Add indexed folder"
        addRootButton.target = self
        addRootButton.action = #selector(addIndexedRoot(_:))

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
        configureIconButton(
            addExclusionButton,
            symbol: "plus",
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

        contentView.addSubview(titleLabel)
        contentView.addSubview(rootsHeader)
        contentView.addSubview(rootsCard)
        contentView.addSubview(exclusionsHeader)
        contentView.addSubview(exclusionsCard)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor, constant: 58),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 52),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -52),

            rootsHeader.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 42),
            rootsHeader.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            rootsHeader.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -52),
            resetRootsButton.widthAnchor.constraint(equalToConstant: 28),
            resetRootsButton.heightAnchor.constraint(equalToConstant: 24),
            addRootButton.widthAnchor.constraint(equalToConstant: 28),
            addRootButton.heightAnchor.constraint(equalToConstant: 24),

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
            addExclusionButton.widthAnchor.constraint(equalToConstant: 28),
            addExclusionButton.heightAnchor.constraint(equalToConstant: 24),

            exclusionsCard.topAnchor.constraint(equalTo: exclusionsHeader.bottomAnchor, constant: 10),
            exclusionsCard.leadingAnchor.constraint(equalTo: rootsCard.leadingAnchor),
            exclusionsCard.trailingAnchor.constraint(equalTo: rootsCard.trailingAnchor),
            exclusionsCard.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -32)
        ])

        return scrollView
    }

    private func makeTitleLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 26, weight: .semibold)
        label.textColor = .labelColor
        return label
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

    private func configureIconButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.title = ""
        button.bezelStyle = .texturedRounded
        button.toolTip = tooltip
        button.target = self
        button.action = action
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
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        configureSettingsTable(
            rootsTableView,
            pasteboardType: Self.indexedRootPasteboardType,
            columnIdentifier: IndexedRootCellView.identifier
        )

        scrollView.documentView = rootsTableView
        card.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: card.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 132)
        ])

        return card
    }

    private func makeExclusionPatternsCard() -> NSView {
        let card = makeCard()

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        configureSettingsTable(
            exclusionsTableView,
            pasteboardType: Self.exclusionPatternPasteboardType,
            columnIdentifier: ExclusionPatternCellView.identifier
        )

        scrollView.documentView = exclusionsTableView

        card.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: card.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
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
        tableView.rowHeight = 42
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
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.layer?.borderWidth = 1
        card.layer?.cornerRadius = 8
        return card
    }

    private func makeSwitchRow(title: String, detail: String, control: NSSwitch) -> NSView {
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
    }

    private func renderExclusionPatterns() {
        exclusionPatterns = AppSettings.exclusionPatterns(defaults: defaults)
        exclusionsTableView.reloadData()
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
        42
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

    private func updateSwitches() {
        highlightSearchTextSwitch.state = defaults.bool(forKey: AppSettings.highlightSearchTextKey) ? .on : .off
        showHiddenFilesSwitch.state = defaults.bool(forKey: AppSettings.showHiddenFilesKey) ? .on : .off
        allowMultipleInstancesSwitch.state = defaults.bool(forKey: AppSettings.allowMultipleInstancesKey) ? .on : .off
        automaticallyCheckForUpdatesSwitch.state = ReleaseUpdater.shared.automaticallyChecksForUpdates ? .on : .off
    }

    @objc private func toggleHighlightSearchText(_ sender: NSSwitch) {
        defaults.set(sender.state == .on, forKey: AppSettings.highlightSearchTextKey)
        defaults.synchronize()
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
        updateSwitches()
    }
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
            layer?.backgroundColor = isSelected
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.28).cgColor
                : NSColor.clear.cgColor
        }
    }

    init(section: SettingsSection) {
        self.section = section
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

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

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }
}
