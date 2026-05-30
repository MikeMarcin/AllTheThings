import AppKit
import ATTCore
import UniformTypeIdentifiers

final class SearchWindowController: NSWindowController {
    private enum WindowLayout {
        static let preferredContentSize = NSSize(width: 1_180, height: 720)
        static let minimumContentSize = NSSize(width: 920, height: 540)
        static let visibleFrameInset: CGFloat = 64
    }

    init(index: FileIndex) {
        let viewController = SearchViewController(index: index)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.startupContentSize()),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "AllTheThings"
        window.titlebarAppearsTransparent = true
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.isRestorable = false
        window.contentMinSize = WindowLayout.minimumContentSize
        window.contentViewController = viewController
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    func focusSearchField(selectText: Bool) {
        guard let viewController = window?.contentViewController as? SearchViewController else { return }
        viewController.focusSearchField(selectText: selectText)
    }

    private static func startupContentSize() -> NSSize {
        guard let visibleFrame = NSScreen.main?.visibleFrame else {
            return WindowLayout.preferredContentSize
        }

        let availableWidth = max(WindowLayout.minimumContentSize.width, visibleFrame.width - WindowLayout.visibleFrameInset)
        let availableHeight = max(WindowLayout.minimumContentSize.height, visibleFrame.height - WindowLayout.visibleFrameInset)

        return NSSize(
            width: min(WindowLayout.preferredContentSize.width, availableWidth),
            height: min(WindowLayout.preferredContentSize.height, availableHeight)
        )
    }
}

private final class SearchViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    private enum Column: String, CaseIterable {
        case name
        case path
        case modified
        case size
        case created
        case ext
        case kind
        case volume

        var title: String {
            switch self {
            case .name: "Name"
            case .path: "Path"
            case .modified: "Modified"
            case .size: "Size"
            case .created: "Created"
            case .ext: "Ext"
            case .kind: "Kind"
            case .volume: "Volume"
            }
        }

        var width: CGFloat {
            switch self {
            case .name: 220
            case .path: 380
            case .modified: 112
            case .size: 72
            case .created: 112
            case .ext: 48
            case .kind: 52
            case .volume: 80
            }
        }

        var sortColumn: SortColumn {
            switch self {
            case .name: .name
            case .path: .path
            case .modified: .modified
            case .size: .size
            case .created: .created
            case .ext: .fileExtension
            case .kind: .kind
            case .volume: .volume
            }
        }

        var menuTitle: String {
            switch self {
            case .name: "Name"
            case .path: "Path"
            case .modified: "Date Modified"
            case .size: "Size"
            case .created: "Date Created"
            case .ext: "Extension"
            case .kind: "Kind"
            case .volume: "Volume"
            }
        }

        static func column(for sortColumn: SortColumn) -> Column? {
            switch sortColumn {
            case .relevance:
                nil
            case .name:
                .name
            case .path:
                .path
            case .modified:
                .modified
            case .created:
                .created
            case .size:
                .size
            case .fileExtension:
                .ext
            case .kind:
                .kind
            case .volume:
                .volume
            }
        }
    }

    private enum TerminalService: CaseIterable {
        case ghosttyTab
        case ghosttyWindow
        case iTermTab
        case iTermWindow

        var title: String {
            switch self {
            case .ghosttyTab: "New Ghostty Tab Here"
            case .ghosttyWindow: "New Ghostty Window Here"
            case .iTermTab: "New iTerm2 Tab Here"
            case .iTermWindow: "New iTerm2 Window Here"
            }
        }

        var bundleIdentifiers: [String] {
            switch self {
            case .ghosttyTab, .ghosttyWindow:
                ["com.mitchellh.ghostty"]
            case .iTermTab, .iTermWindow:
                ["com.googlecode.iterm2"]
            }
        }

        var fallbackAppNames: [String] {
            switch self {
            case .ghosttyTab, .ghosttyWindow:
                ["Ghostty"]
            case .iTermTab, .iTermWindow:
                ["iTerm", "iTerm2"]
            }
        }
    }

    private struct SearchSignature: Equatable {
        let query: String
        let sort: SortSpec
        let includeHidden: Bool
    }

    private let index: FileIndex
    private let watcher = FileSystemWatcher()
    private let searchQueue = DispatchQueue(label: "att.search", qos: .userInitiated)
    private let defaults = UserDefaults.standard

    private let searchField = NSSearchField()
    private let setupSuggestionPanel = SetupSuggestionPanelView()
    private let tableView = FileTableView()
    private let headerMenu = NSMenu()
    private let scrollView = NSScrollView()
    private let mascotSlotView = NSView()
    private let mascotImageView = NSImageView()
    private let expandedMascotView = ClickableMascotView()
    private let expandedMascotImageView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton()
    private let revealButton = NSButton()
    private let copyButton = NSButton()
    private let addScopeButton = NSButton()
    private let reindexButton = NSButton()
    private let loadingOverlay = ThemedBackgroundView(backgroundColor: NSColor.windowBackgroundColor.withAlphaComponent(0.92))
    private let loadingMascotImageView = NSImageView()
    private let loadingLabel = NSTextField(labelWithString: "Loading file list...")
    private let indexingSetupOverlay = IndexingSetupOverlayView()

    private var results: [SearchResult] = []
    private var indexStats: IndexStats
    private var totalMatches = 0
    private var queryElapsed: TimeInterval = 0
    private var queryGeneration: UInt64 = 0
    private var activeSearchToken: SearchCancellationToken?
    private var scheduledSearchSignature: SearchSignature?
    private var displayedSearchSignature: SearchSignature?
    private var sortSpec: SortSpec
    private var visibleColumns: Set<Column>
    private var indexedRoots: [URL]
    private var pendingEventPaths = Set<String>()
    private var eventDebounce: DispatchWorkItem?
    private var memoryStatusTask: Task<Void, Never>?
    private var memoryStatusText = ProcessMemoryFormatter.label(for: ProcessMemorySampler.currentUsage())
    private var mascotCoordinator: OperationMascotCoordinator?
    private var expandedMascotCoordinator: OperationMascotCoordinator?
    private var loadingMascotCoordinator: OperationMascotCoordinator?
    private var expandedMascotLeadingConstraint: NSLayoutConstraint?
    private var expandedMascotImageBottomConstraint: NSLayoutConstraint?
    private var isExpandedMascotVisible = false
    private var userExpandedMascot = false
    private var userCollapsedExpandedMascotDuringOperation = false
    private var wasImportantMascotOperationActive = false
    private var didRequestInitialSnapshotLoad = false
    private var didRequestInitialRebuild = false
    private var highlightsSearchText: Bool
    private var showsHiddenFiles: Bool

    private enum DefaultsKey {
        static let sortColumn = "ATTSortColumn"
        static let sortAscending = "ATTSortAscending"
        static let visibleColumns = "ATTVisibleColumns"
    }

    private enum ExpandedMascotLayout {
        static let leadingOffset: CGFloat = -24
        static let spriteFrameAspectRatio: CGFloat = 96.0 / 160.0
    }

    private static let defaultSortSpec = SortSpec(column: .name, ascending: true)
    private static let defaultVisibleColumns = Set(Column.allCases)

    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d/yyyy HH:mm"
        return formatter
    }()

    private lazy var byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    init(index: FileIndex) {
        let defaults = UserDefaults.standard
        AppSettings.registerDefaults(defaults)
        let visibleColumns = Self.loadVisibleColumns(defaults: defaults)
        self.index = index
        self.indexStats = index.currentStats()
        self.visibleColumns = visibleColumns
        self.sortSpec = Self.normalizedSortSpec(Self.loadSortSpec(defaults: defaults), visibleColumns: visibleColumns)
        self.indexedRoots = AppSettings.indexedRoots(defaults: defaults)
        self.highlightsSearchText = defaults.bool(forKey: AppSettings.highlightSearchTextKey)
        self.showsHiddenFiles = defaults.bool(forKey: AppSettings.showHiddenFilesKey)
        super.init(nibName: nil, bundle: nil)
    }

    deinit {
        memoryStatusTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = ThemedBackgroundView()
        rootView.appearanceDidChange = { [weak self] in
            self?.tableView.reloadData()
        }
        view = rootView
        buildInterface()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        index.onStatsChanged = { @MainActor @Sendable [weak self] stats in
            self?.handleStatsChanged(stats)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange(_:)),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
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

        startWatchingIfNeeded()
        startMemoryStatusPolling()
        updateLoadingOverlay()

        if indexStats.indexedCount > 0 {
            scheduleSearch(force: true)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusSearchField(selectText: false)

        DispatchQueue.main.async { [weak self] in
            self?.startIndexingAfterFirstPaint()
        }
    }

    @MainActor
    func focusSearchField(selectText: Bool) {
        view.window?.makeFirstResponder(searchField)
        if selectText {
            searchField.selectText(nil)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard
            row >= 0,
            row < results.count,
            let tableColumn,
            let column = Column(rawValue: tableColumn.identifier.rawValue)
        else {
            return nil
        }

        let cell = makeCell(for: tableColumn.identifier)
        let record = results[row].record
        let textField = cell.textField

        switch column {
        case .name:
            textField?.attributedStringValue = highlightedName(record.name)
            textField?.lineBreakMode = .byTruncatingMiddle
        case .path:
            textField?.stringValue = AppSettings.displayPath(record.directoryPath)
            textField?.textColor = .secondaryLabelColor
            textField?.lineBreakMode = .byTruncatingMiddle
        case .modified:
            textField?.stringValue = dateFormatter.string(from: record.modifiedDate)
            textField?.textColor = .labelColor
        case .size:
            textField?.stringValue = record.isDirectory ? "Folder" : byteFormatter.string(fromByteCount: Int64(record.sizeBytes))
            textField?.textColor = .labelColor
            textField?.alignment = .right
        case .created:
            textField?.stringValue = record.createdDate.map(dateFormatter.string(from:)) ?? ""
            textField?.textColor = .labelColor
        case .ext:
            textField?.stringValue = record.fileExtension
            textField?.textColor = .secondaryLabelColor
        case .kind:
            textField?.stringValue = record.isDirectory ? "Folder" : "File"
            textField?.textColor = .labelColor
        case .volume:
            textField?.stringValue = record.volumeName
            textField?.textColor = .secondaryLabelColor
        }

        if column != .size {
            textField?.alignment = .left
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateActionButtons()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row >= 0, row < results.count else { return nil }
        return results[row].record.url as NSURL
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first else { return }
        sortSpec = sortSpec(for: descriptor)
        saveSortSpec()
        scheduleSearch(force: true)
    }

    func controlTextDidChange(_ obj: Notification) {
        scheduleSearch()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === headerMenu {
            populateHeaderMenu(menu)
            return
        }

        menu.removeAllItems()
        let records = selectedRecords()
        let hasSelection = !records.isEmpty
        let hasSingleSelection = records.count == 1

        menu.addItem(actionItem("Open", #selector(openSelected(_:)), enabled: hasSelection))
        menu.addItem(openWithMenuItem(enabled: hasSingleSelection))
        menu.addItem(.separator())
        menu.addItem(actionItem("Move to Trash", #selector(moveSelectedToTrash(_:)), enabled: hasSelection))
        menu.addItem(.separator())
        menu.addItem(actionItem("Get Info", #selector(getInfoSelected(_:)), enabled: hasSingleSelection))
        menu.addItem(actionItem("Rename", #selector(renameSelected(_:)), enabled: hasSingleSelection))
        menu.addItem(actionItem("Quick Look", #selector(quickLookSelected(_:)), enabled: hasSelection))
        menu.addItem(.separator())
        menu.addItem(actionItem("Copy", #selector(copy(_:)), enabled: hasSelection))
        menu.addItem(actionItem("Copy Path", #selector(copySelectedPath(_:)), enabled: hasSelection))
        menu.addItem(actionItem("Reveal in Finder", #selector(revealSelected(_:)), enabled: hasSelection))

        let terminalItems = terminalMenuItems(enabled: hasSingleSelection)
        if !terminalItems.isEmpty {
            menu.addItem(.separator())
            terminalItems.forEach { menu.addItem($0) }
        }
    }

    private func buildInterface() {
        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .width
        rootStack.spacing = 0
        rootStack.detachesHiddenViews = true
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        let topBar = NSStackView()
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.spacing = 8
        topBar.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 8, right: 14)
        topBar.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search filenames and paths"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldDidChange(_:))
        searchField.controlSize = .large
        searchField.font = .systemFont(ofSize: 16)
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        topBar.addArrangedSubview(searchField)

        configureToolbarButton(addScopeButton, symbol: "folder.badge.plus", tooltip: "Add indexed folder", action: #selector(addScope(_:)))
        configureToolbarButton(reindexButton, symbol: "arrow.clockwise", tooltip: "Reindex scopes", action: #selector(reindex(_:)))
        configureToolbarButton(openButton, symbol: "arrow.up.forward.app", tooltip: "Open selected file", action: #selector(openSelected(_:)))
        configureToolbarButton(revealButton, symbol: "folder", tooltip: "Reveal selected file in Finder", action: #selector(revealSelected(_:)))
        configureToolbarButton(copyButton, symbol: "doc.on.doc", tooltip: "Copy selected path", action: #selector(copySelectedPath(_:)))

        for button in [addScopeButton, reindexButton, openButton, revealButton, copyButton] {
            topBar.addArrangedSubview(button)
        }

        configureSetupSuggestionPanel()

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = tableView

        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowSizeStyle = .small
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 3, height: 1)
        tableView.style = .fullWidth
        tableView.allowsMultipleSelection = true
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.doubleAction = #selector(openSelected(_:))
        tableView.target = self
        tableView.copyAction = { [weak self] in
            self?.copySelectedFiles()
        }
        tableView.copyPathAction = { [weak self] in
            self?.copySelectedPath(nil)
        }

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        headerMenu.delegate = self
        tableView.headerView?.menu = headerMenu

        for column in Column.allCases where visibleColumns.contains(column) {
            tableView.addTableColumn(makeTableColumn(for: column))
        }
        tableView.sortDescriptors = [sortDescriptor(for: sortSpec)]

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12
        footer.edgeInsets = NSEdgeInsets(top: 7, left: 14, bottom: 10, right: 14)
        footer.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureMascotSlotView()
        mascotCoordinator = OperationMascotCoordinator(imageView: mascotImageView)
        footer.addArrangedSubview(mascotSlotView)
        footer.addArrangedSubview(countLabel)
        footer.addArrangedSubview(statusLabel)
        updateMascotPersistentAnimation()

        rootStack.addArrangedSubview(topBar)
        rootStack.addArrangedSubview(setupSuggestionPanel)
        rootStack.addArrangedSubview(scrollView)
        rootStack.addArrangedSubview(footer)
        view.addSubview(rootStack)
        configureIndexingSetupOverlay()
        configureLoadingOverlay()
        configureExpandedMascotOverlay()

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            topBar.leadingAnchor.constraint(equalTo: rootStack.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: rootStack.trailingAnchor),
            setupSuggestionPanel.leadingAnchor.constraint(equalTo: rootStack.leadingAnchor),
            setupSuggestionPanel.trailingAnchor.constraint(equalTo: rootStack.trailingAnchor),
            scrollView.leadingAnchor.constraint(equalTo: rootStack.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootStack.trailingAnchor),
            footer.leadingAnchor.constraint(equalTo: rootStack.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: rootStack.trailingAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),

            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 400),

            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),

            loadingOverlay.topAnchor.constraint(equalTo: scrollView.topAnchor),
            loadingOverlay.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            loadingOverlay.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            loadingOverlay.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor)
        ])

        updateActionButtons()
        updateStatus()
        updateSetupSuggestions()
        updateLoadingOverlay()
        updateExpandedMascotForOperation(animated: false)
    }

    private func configureMascotSlotView() {
        mascotSlotView.translatesAutoresizingMaskIntoConstraints = false
        mascotSlotView.wantsLayer = true
        mascotSlotView.layer?.masksToBounds = false
        mascotSlotView.toolTip = "Toggle large Nib"
        mascotSlotView.setContentHuggingPriority(.required, for: .horizontal)
        mascotSlotView.setContentCompressionResistancePriority(.required, for: .horizontal)
        mascotSlotView.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(toggleExpandedMascot(_:))))

        mascotSlotView.addSubview(mascotImageView)
        mascotImageView.translatesAutoresizingMaskIntoConstraints = false
        mascotImageView.imageAlignment = .alignCenter
        mascotImageView.toolTip = "Toggle large Nib"
        NSLayoutConstraint.activate([
            mascotSlotView.widthAnchor.constraint(equalToConstant: OperationMascotCoordinator.layoutSize),
            mascotSlotView.heightAnchor.constraint(equalToConstant: OperationMascotCoordinator.layoutSize),
            mascotImageView.centerXAnchor.constraint(equalTo: mascotSlotView.centerXAnchor),
            mascotImageView.centerYAnchor.constraint(equalTo: mascotSlotView.centerYAnchor)
        ])
    }

    private func configureExpandedMascotOverlay() {
        expandedMascotView.translatesAutoresizingMaskIntoConstraints = false
        expandedMascotView.wantsLayer = true
        expandedMascotView.layer?.masksToBounds = false
        expandedMascotView.alphaValue = 1
        expandedMascotView.isHidden = true
        expandedMascotView.toolTip = "Shrink Nib"
        expandedMascotView.onClick = { [weak self] in
            self?.toggleExpandedMascot(nil)
        }

        expandedMascotView.addSubview(expandedMascotImageView)
        expandedMascotImageView.translatesAutoresizingMaskIntoConstraints = false
        expandedMascotImageView.imageAlignment = .alignCenter
        expandedMascotCoordinator = OperationMascotCoordinator(
            imageView: expandedMascotImageView,
            displaySize: OperationMascotCoordinator.statusDisplaySize
        )

        view.addSubview(expandedMascotView)
        let leadingConstraint = expandedMascotView.leadingAnchor.constraint(
            equalTo: view.leadingAnchor,
            constant: ExpandedMascotLayout.leadingOffset
        )
        expandedMascotLeadingConstraint = leadingConstraint
        let imageBottomConstraint = expandedMascotImageView.bottomAnchor.constraint(equalTo: expandedMascotView.bottomAnchor)
        expandedMascotImageBottomConstraint = imageBottomConstraint
        NSLayoutConstraint.activate([
            leadingConstraint,
            expandedMascotView.bottomAnchor.constraint(equalTo: mascotImageView.bottomAnchor),
            expandedMascotView.widthAnchor.constraint(equalToConstant: OperationMascotCoordinator.expandedDisplaySize),
            expandedMascotView.heightAnchor.constraint(equalToConstant: OperationMascotCoordinator.expandedDisplaySize),
            expandedMascotImageView.leadingAnchor.constraint(equalTo: expandedMascotView.leadingAnchor),
            imageBottomConstraint
        ])

        expandedMascotCoordinator?.setPersistentAnimation(persistentMascotAnimation())
    }

    private func configureSetupSuggestionPanel() {
        setupSuggestionPanel.translatesAutoresizingMaskIntoConstraints = false
        setupSuggestionPanel.openFullDiskAccessButton.target = self
        setupSuggestionPanel.openFullDiskAccessButton.action = #selector(openSuggestedFullDiskAccessSettings(_:))
        setupSuggestionPanel.enableGlobalHotKeyButton.target = self
        setupSuggestionPanel.enableGlobalHotKeyButton.action = #selector(enableSuggestedGlobalHotKey(_:))
        setupSuggestionPanel.chooseGlobalHotKeyButton.target = self
        setupSuggestionPanel.chooseGlobalHotKeyButton.action = #selector(chooseSuggestedGlobalHotKey(_:))
        setupSuggestionPanel.dismissGlobalHotKeyButton.target = self
        setupSuggestionPanel.dismissGlobalHotKeyButton.action = #selector(dismissSuggestedGlobalHotKey(_:))
        setupSuggestionPanel.dismissFullDiskAccessButton.target = self
        setupSuggestionPanel.dismissFullDiskAccessButton.action = #selector(dismissSuggestedFullDiskAccess(_:))
    }

    private func configureIndexingSetupOverlay() {
        indexingSetupOverlay.translatesAutoresizingMaskIntoConstraints = false
        indexingSetupOverlay.startIndexingButton.target = self
        indexingSetupOverlay.startIndexingButton.action = #selector(startSuggestedIndexing(_:))
        indexingSetupOverlay.chooseIndexedFoldersButton.target = self
        indexingSetupOverlay.chooseIndexedFoldersButton.action = #selector(chooseSuggestedIndexedFolders(_:))

        view.addSubview(indexingSetupOverlay)
        NSLayoutConstraint.activate([
            indexingSetupOverlay.topAnchor.constraint(equalTo: scrollView.topAnchor),
            indexingSetupOverlay.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            indexingSetupOverlay.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            indexingSetupOverlay.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor)
        ])
    }

    private func updateSetupSuggestions() {
        let needsIndexingSetup = !AppSettings.indexedRootsConfigured(defaults: defaults)
        let needsGlobalHotKey = AppSettings.globalSearchHotKeyNeedsConfirmation(defaults: defaults)
        let needsFullDiskAccess = !defaults.bool(forKey: AppSettings.fullDiskAccessOnboardingShownKey)
            && (needsIndexingSetup || !FullDiskAccessController.protectedDefaultFoldersCovered(by: indexedRoots).isEmpty)

        indexingSetupOverlay.isHidden = !needsIndexingSetup
        setupSuggestionPanel.update(
            hotKey: AppSettings.globalSearchHotKey(defaults: defaults),
            needsGlobalHotKey: needsGlobalHotKey,
            needsFullDiskAccess: needsFullDiskAccess
        )
    }

    @objc private func enableSuggestedGlobalHotKey(_ sender: NSButton) {
        let hotKey = AppSettings.globalSearchHotKey(defaults: defaults)

        do {
            if let appDelegate = NSApp.delegate as? AppDelegate {
                try appDelegate.saveGlobalSearchHotKey(enabled: true, hotKey: hotKey)
            } else {
                AppSettings.saveGlobalSearchHotKey(enabled: true, hotKey: hotKey, defaults: defaults)
            }
        } catch {
            presentError("Could not register global search hotkey.", informativeText: error.localizedDescription)
        }

        updateSetupSuggestions()
    }

    @objc private func chooseSuggestedGlobalHotKey(_ sender: NSButton) {
        AppSettings.saveGlobalSearchHotKey(
            enabled: false,
            hotKey: AppSettings.globalSearchHotKey(defaults: defaults),
            defaults: defaults
        )
        (NSApp.delegate as? AppDelegate)?.showSettings()
        updateSetupSuggestions()
    }

    @objc private func openSuggestedFullDiskAccessSettings(_ sender: NSButton) {
        markFullDiskAccessOnboardingShown()
        FullDiskAccessController.openSystemSettings()
        updateSetupSuggestions()
    }

    @objc private func dismissSuggestedGlobalHotKey(_ sender: NSButton) {
        AppSettings.saveGlobalSearchHotKey(
            enabled: false,
            hotKey: AppSettings.globalSearchHotKey(defaults: defaults),
            defaults: defaults
        )
        updateSetupSuggestions()
    }

    @objc private func dismissSuggestedFullDiskAccess(_ sender: NSButton) {
        markFullDiskAccessOnboardingShown()
        updateSetupSuggestions()
    }

    @objc private func startSuggestedIndexing(_ sender: NSButton) {
        let roots = AppSettings.suggestedDefaultIndexedRoots()
        indexedRoots = roots
        saveRoots()
        startWatchingIfNeeded()
        rebuildIndexForCurrentSettings()
        updateSetupSuggestions()
    }

    @objc private func chooseSuggestedIndexedFolders(_ sender: NSButton) {
        presentIndexedFolderChooser(prompt: "Index")
    }

    private func markFullDiskAccessOnboardingShown() {
        defaults.set(true, forKey: AppSettings.fullDiskAccessOnboardingShownKey)
        defaults.synchronize()
    }

    private func configureLoadingOverlay() {
        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false

        loadingMascotImageView.translatesAutoresizingMaskIntoConstraints = false
        loadingMascotCoordinator = OperationMascotCoordinator(
            imageView: loadingMascotImageView,
            displaySize: OperationMascotCoordinator.heroDisplaySize
        )

        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel.font = .systemFont(ofSize: 14, weight: .medium)
        loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.alignment = .center
        loadingLabel.lineBreakMode = .byWordWrapping
        loadingLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [loadingMascotImageView, loadingLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12

        loadingOverlay.addSubview(stack)
        view.addSubview(loadingOverlay)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: loadingOverlay.centerYAnchor)
        ])

        loadingMascotCoordinator?.setPersistentAnimation(persistentMascotAnimation())
    }

    private func configureToolbarButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.title = ""
        button.toolTip = tooltip
        button.bezelStyle = .texturedRounded
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    private func makeTableColumn(for column: Column) -> NSTableColumn {
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
        tableColumn.title = column.title
        tableColumn.width = column.width
        tableColumn.minWidth = min(column.width, 48)
        tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column != .modified && column != .size)
        return tableColumn
    }

    private func populateHeaderMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        for column in Column.allCases where column != .name {
            let item = NSMenuItem(title: column.menuTitle, action: #selector(toggleColumnVisibility(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            item.state = visibleColumns.contains(column) ? .on : .off
            menu.addItem(item)
        }
    }

    private func actionItem(_ title: String, _ selector: Selector, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    private func openWithMenuItem(enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        item.isEnabled = enabled

        let submenu = NSMenu(title: "Open With")
        guard enabled, let record = selectedRecord() else {
            let unavailable = NSMenuItem(title: "No Applications", action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            submenu.addItem(unavailable)
            item.submenu = submenu
            return item
        }

        let applicationURLs = NSWorkspace.shared.urlsForApplications(toOpen: record.url)
        if applicationURLs.isEmpty {
            let unavailable = NSMenuItem(title: "No Applications", action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            submenu.addItem(unavailable)
        } else {
            for applicationURL in applicationURLs.prefix(12) {
                let applicationName = FileManager.default.displayName(atPath: applicationURL.path)
                let applicationItem = NSMenuItem(title: applicationName, action: #selector(openSelectedWithApplication(_:)), keyEquivalent: "")
                applicationItem.target = self
                applicationItem.representedObject = applicationURL
                applicationItem.image = NSWorkspace.shared.icon(forFile: applicationURL.path)
                applicationItem.image?.size = NSSize(width: 16, height: 16)
                submenu.addItem(applicationItem)
            }
        }

        submenu.addItem(.separator())
        submenu.addItem(actionItem("Other...", #selector(openSelectedWithOtherApplication(_:)), enabled: true))
        item.submenu = submenu
        return item
    }

    private func terminalMenuItems(enabled: Bool) -> [NSMenuItem] {
        TerminalService.allCases.compactMap { service in
            guard isApplicationInstalled(bundleIdentifiers: service.bundleIdentifiers, fallbackAppNames: service.fallbackAppNames) else {
                return nil
            }

            let item = NSMenuItem(title: service.title, action: #selector(openTerminalHere(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = service.title
            item.isEnabled = enabled
            return item
        }
    }

    private func makeCell(for identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        if let reusable = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            return reusable
        }

        let cell = NSTableCellView()
        cell.identifier = identifier
        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byTruncatingMiddle
        textField.font = .systemFont(ofSize: 12)
        cell.addSubview(textField)
        cell.textField = textField

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])

        return cell
    }

    private func scheduleSearch(force: Bool = false) {
        guard !indexStats.isLoadingSnapshot else { return }

        let request = SearchRequest(query: currentSearchText(), sort: sortSpec, includeHidden: showsHiddenFiles)
        let signature = SearchSignature(
            query: request.query,
            sort: request.sort,
            includeHidden: request.includeHidden
        )
        let signatureChanged = signature != scheduledSearchSignature
        guard force || signatureChanged else { return }

        if activeSearchToken != nil, force, !signatureChanged {
            return
        }

        scheduledSearchSignature = signature

        activeSearchToken?.cancel()
        let token = SearchCancellationToken()
        activeSearchToken = token
        updateMascotPersistentAnimation()

        if signature != displayedSearchSignature {
            results = []
            totalMatches = 0
            queryElapsed = 0
            tableView.reloadData()
            updateStatus()
            updateLoadingOverlay()
            updateActionButtons()
        }

        queryGeneration &+= 1
        let generation = queryGeneration
        let index = self.index

        searchQueue.async {
            guard !token.isCancelled else {
                DispatchQueue.main.async { [weak self] in
                    self?.clearSearchTokenIfCurrent(token)
                }
                return
            }

            guard let response = index.search(request, shouldCancel: { token.isCancelled }) else {
                DispatchQueue.main.async { [weak self] in
                    self?.clearSearchTokenIfCurrent(token)
                }
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.queryGeneration == generation, self.activeSearchToken === token else { return }
                self.activeSearchToken = nil
                self.results = response.results
                self.totalMatches = response.totalMatches
                self.queryElapsed = response.elapsed
                self.displayedSearchSignature = signature
                self.tableView.reloadData()
                self.updateStatus(refreshesMemory: true)
                self.updateLoadingOverlay()
                self.updateActionButtons()
                self.updateMascotPersistentAnimation()
                if
                    response.usesIndexedCandidates,
                    let responseRevision = response.snapshotRevision,
                    responseRevision < self.indexStats.snapshotRevision,
                    signature == self.scheduledSearchSignature
                {
                    self.scheduleSearch(force: true)
                }
            }
        }
    }

    private func clearSearchTokenIfCurrent(_ token: SearchCancellationToken) {
        guard activeSearchToken === token else { return }
        activeSearchToken = nil
        updateLoadingOverlay()
        updateMascotPersistentAnimation()
    }

    private func handleStatsChanged(_ stats: IndexStats) {
        let previousPhase = indexStats.phase
        indexStats = stats
        handleMascotTransition(from: previousPhase, to: stats.phase)
        updateStatus(refreshesMemory: true)
        updateLoadingOverlay()

        guard AppSettings.indexedRootsConfigured(defaults: defaults), !indexedRoots.isEmpty else {
            return
        }

        guard !stats.isLoadingSnapshot else { return }

        guard indexSettingsMatchConfiguredSettings() else {
            startInitialRebuildIfNeeded()
            return
        }

        if stats.indexedCount == 0, !stats.isIndexing {
            startInitialRebuildIfNeeded()
            return
        }

        scheduleSearch(force: true)
    }

    private func startIndexingAfterFirstPaint() {
        guard !didRequestInitialSnapshotLoad else { return }
        didRequestInitialSnapshotLoad = true
        updateLoadingOverlay()

        guard AppSettings.indexedRootsConfigured(defaults: defaults), !indexedRoots.isEmpty else {
            updateStatus()
            updateSetupSuggestions()
            return
        }

        if indexStats.indexedCount > 0 {
            scheduleSearch(force: true)
            return
        }

        if index.loadSnapshotInBackground() {
            return
        }

        startInitialRebuildIfNeeded()
    }

    private func startInitialRebuildIfNeeded() {
        guard
            didRequestInitialSnapshotLoad,
            !didRequestInitialRebuild,
            AppSettings.indexedRootsConfigured(defaults: defaults),
            !indexedRoots.isEmpty
        else {
            return
        }

        didRequestInitialRebuild = true
        index.replaceRootsAndRebuild(indexedRoots)
    }

    private func updateLoadingOverlay() {
        guard AppSettings.indexedRootsConfigured(defaults: defaults), !indexedRoots.isEmpty else {
            loadingOverlay.isHidden = true
            updateMascotPlacementVisibility()
            return
        }

        let waitingForInitialLoad = !didRequestInitialSnapshotLoad && indexStats.indexedCount == 0
        let shouldShow = indexStats.isLoadingSnapshot || waitingForInitialLoad

        if indexStats.isLoadingSnapshot || waitingForInitialLoad {
            loadingLabel.stringValue = "Loading file list..."
        } else {
            loadingLabel.stringValue = indexStats.status
        }

        loadingOverlay.isHidden = !shouldShow
        updateMascotPlacementVisibility()
    }

    private func handleMascotTransition(from previousPhase: IndexPhase, to nextPhase: IndexPhase) {
        updateMascotPersistentAnimation()
        updateExpandedMascotForOperation(animated: true)

        if nextPhase == .failed {
            playMascotTransient(.error)
            return
        }

        let completedPhases: Set<IndexPhase> = [.scanning, .optimizing, .saving]
        if completedPhases.contains(previousPhase), nextPhase == .ready {
            playMascotTransient(.success)
        }
    }

    private func updateMascotPersistentAnimation() {
        let animation = persistentMascotAnimation()
        mascotCoordinator?.setPersistentAnimation(animation)
        expandedMascotCoordinator?.setPersistentAnimation(animation)
        loadingMascotCoordinator?.setPersistentAnimation(animation)
    }

    private func playMascotTransient(_ animation: OperationMascotAnimation) {
        mascotCoordinator?.playTransient(animation)
        expandedMascotCoordinator?.playTransient(animation)
        loadingMascotCoordinator?.playTransient(animation)
    }

    @objc private func toggleExpandedMascot(_ sender: Any?) {
        let importantOperationActive = isImportantMascotOperation(indexStats.phase)

        if isExpandedMascotVisible {
            userExpandedMascot = false
            if importantOperationActive {
                userCollapsedExpandedMascotDuringOperation = true
            }
            setExpandedMascotVisible(false, animated: true)
            return
        }

        if importantOperationActive {
            userCollapsedExpandedMascotDuringOperation = false
        } else {
            userExpandedMascot = true
        }
        setExpandedMascotVisible(true, animated: true)
    }

    private func updateExpandedMascotForOperation(animated: Bool) {
        let importantOperationActive = isImportantMascotOperation(indexStats.phase)

        if importantOperationActive && !wasImportantMascotOperationActive {
            userCollapsedExpandedMascotDuringOperation = false
        }
        wasImportantMascotOperationActive = importantOperationActive

        if importantOperationActive {
            if !userCollapsedExpandedMascotDuringOperation {
                setExpandedMascotVisible(true, animated: animated)
            }
        } else {
            userCollapsedExpandedMascotDuringOperation = false
            if !userExpandedMascot {
                setExpandedMascotVisible(false, animated: animated)
            }
        }
    }

    private func isImportantMascotOperation(_ phase: IndexPhase) -> Bool {
        switch phase {
        case .scanning, .optimizing, .saving:
            return true
        case .idle, .loading, .ready, .failed:
            return false
        }
    }

    private func footerMascotLeadingOffset() -> CGFloat {
        view.layoutSubtreeIfNeeded()
        return mascotImageView.convert(mascotImageView.bounds, to: view).minX
    }

    private func expandedMascotImageBottomOffset(for displaySize: CGFloat) -> CGFloat {
        let visiblePadding = (OperationMascotCoordinator.statusDisplaySize * (1 - ExpandedMascotLayout.spriteFrameAspectRatio)) / 2
        let targetPadding = (displaySize * (1 - ExpandedMascotLayout.spriteFrameAspectRatio)) / 2
        return targetPadding - visiblePadding
    }

    private func setExpandedMascotVisible(_ visible: Bool, animated: Bool) {
        guard isExpandedMascotVisible != visible else {
            updateMascotPlacementVisibility()
            return
        }

        isExpandedMascotVisible = visible
        expandedMascotView.toolTip = visible ? "Shrink Nib" : "Grow Nib"
        mascotSlotView.toolTip = visible ? "Shrink Nib" : "Grow Nib"
        mascotImageView.toolTip = visible ? "Shrink Nib" : "Grow Nib"

        let collapsedSize = OperationMascotCoordinator.statusDisplaySize
        let targetSize = visible ? OperationMascotCoordinator.expandedDisplaySize : collapsedSize
        let footerLeadingOffset = footerMascotLeadingOffset()
        let targetLeadingOffset = visible ? ExpandedMascotLayout.leadingOffset : footerLeadingOffset
        let targetBottomOffset = expandedMascotImageBottomOffset(for: targetSize)
        if visible && !loadingOverlay.isHidden {
            expandedMascotLeadingConstraint?.constant = ExpandedMascotLayout.leadingOffset
            expandedMascotImageBottomConstraint?.constant = targetBottomOffset
            expandedMascotCoordinator?.setDisplaySize(targetSize)
            updateMascotPlacementVisibility()
            return
        }

        if visible {
            expandedMascotLeadingConstraint?.constant = footerLeadingOffset
            expandedMascotImageBottomConstraint?.constant = expandedMascotImageBottomOffset(for: collapsedSize)
            expandedMascotCoordinator?.setDisplaySize(collapsedSize)
            expandedMascotView.isHidden = false
            mascotImageView.isHidden = true
            view.layoutSubtreeIfNeeded()
        }

        guard animated else {
            expandedMascotLeadingConstraint?.constant = targetLeadingOffset
            expandedMascotImageBottomConstraint?.constant = targetBottomOffset
            expandedMascotCoordinator?.setDisplaySize(targetSize)
            updateMascotPlacementVisibility()
            return
        }

        if !visible {
            mascotImageView.isHidden = true
            expandedMascotView.isHidden = false
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.allowsImplicitAnimation = true
            self.expandedMascotLeadingConstraint?.animator().constant = targetLeadingOffset
            self.expandedMascotImageBottomConstraint?.animator().constant = targetBottomOffset
            self.expandedMascotCoordinator?.setDisplaySize(targetSize, animated: true)
            self.view.layoutSubtreeIfNeeded()
        } completionHandler: {
            if !visible {
                self.updateMascotPlacementVisibility()
                self.expandedMascotCoordinator?.setDisplaySize(collapsedSize)
                self.expandedMascotImageBottomConstraint?.constant = self.expandedMascotImageBottomOffset(for: collapsedSize)
                self.expandedMascotLeadingConstraint?.constant = ExpandedMascotLayout.leadingOffset
                return
            }
            self.updateMascotPlacementVisibility()
        }
    }

    private func updateMascotPlacementVisibility() {
        let loadingMascotVisible = !loadingOverlay.isHidden

        loadingMascotImageView.isHidden = !loadingMascotVisible
        expandedMascotView.isHidden = loadingMascotVisible || !isExpandedMascotVisible
        mascotImageView.isHidden = loadingMascotVisible || isExpandedMascotVisible
    }

    private func persistentMascotAnimation() -> OperationMascotAnimation {
        switch indexStats.phase {
        case .loading, .scanning:
            return .indexing
        case .optimizing, .saving:
            return .optimizing
        case .idle, .ready, .failed:
            break
        }

        return activeSearchToken == nil ? .idle : .searching
    }

    private func currentSearchText() -> String {
        (searchField.currentEditor()?.string ?? searchField.stringValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func settingsDidChange() {
        let updatedHighlightsSearchText = defaults.bool(forKey: AppSettings.highlightSearchTextKey)
        let updatedShowsHiddenFiles = defaults.bool(forKey: AppSettings.showHiddenFilesKey)

        if updatedHighlightsSearchText != highlightsSearchText {
            highlightsSearchText = updatedHighlightsSearchText
            tableView.reloadData()
        }

        if updatedShowsHiddenFiles != showsHiddenFiles {
            showsHiddenFiles = updatedShowsHiddenFiles
            scheduleSearch(force: true)
        }
    }

    @objc private func userDefaultsDidChange(_ notification: Notification) {
        settingsDidChange()
        updateSetupSuggestions()
    }

    @objc private func indexedRootsDidChange(_ notification: Notification) {
        let updatedRoots = AppSettings.indexedRoots(defaults: defaults)
        guard rootPaths(updatedRoots) != rootPaths(indexedRoots) else {
            updateSetupSuggestions()
            updateLoadingOverlay()
            updateStatus()
            updateActionButtons()
            return
        }

        indexedRoots = updatedRoots
        didRequestInitialRebuild = false
        startWatchingIfNeeded()
        rebuildIndexForCurrentSettings()
        updateSetupSuggestions()
        updateActionButtons()
    }

    @objc private func exclusionPatternsDidChange(_ notification: Notification) {
        let patterns = AppSettings.exclusionPatterns(defaults: defaults)
        guard patterns != index.allExclusionPatterns() else { return }

        index.updateExclusionPatterns(patterns)
        guard AppSettings.indexedRootsConfigured(defaults: defaults) else { return }
        rebuildIndexForCurrentSettings()
    }

    private func rebuildIndexForCurrentSettings() {
        activeSearchToken?.cancel()
        activeSearchToken = nil
        scheduledSearchSignature = nil
        displayedSearchSignature = nil
        results.removeAll(keepingCapacity: true)
        totalMatches = 0
        queryElapsed = 0
        tableView.reloadData()
        updateStatus()
        updateLoadingOverlay()
        updateActionButtons()
        updateMascotPersistentAnimation()

        guard AppSettings.indexedRootsConfigured(defaults: defaults) else {
            updateStatus()
            updateLoadingOverlay()
            updateActionButtons()
            return
        }

        didRequestInitialSnapshotLoad = true
        didRequestInitialRebuild = true
        index.replaceRootsAndRebuild(indexedRoots)
    }

    private func indexSettingsMatchConfiguredSettings() -> Bool {
        guard index.allExclusionPatterns() == AppSettings.exclusionPatterns(defaults: defaults) else {
            return false
        }

        let indexRoots = index.allRoots()
        guard !indexRoots.isEmpty else {
            return indexStats.indexedCount == 0
        }

        return rootPaths(indexRoots) == rootPaths(indexedRoots)
    }

    private func rootPaths(_ roots: [URL]) -> [String] {
        roots.map(\.standardizedFileURL.path)
    }

    private func startWatchingIfNeeded() {
        guard AppSettings.indexedRootsConfigured(defaults: defaults), !indexedRoots.isEmpty else {
            watcher.stop()
            return
        }

        watcher.start(roots: indexedRoots) { @MainActor @Sendable [weak self] paths in
            self?.coalesceFSEvents(paths)
        }
    }

    private func coalesceFSEvents(_ paths: [String]) {
        pendingEventPaths.formUnion(paths)
        eventDebounce?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let paths = Array(self.pendingEventPaths)
            self.pendingEventPaths.removeAll(keepingCapacity: false)
            guard !paths.isEmpty else { return }
            self.playMascotTransient(.fileChanged)
            self.index.refresh(paths: paths)
        }

        eventDebounce = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    private func startMemoryStatusPolling() {
        guard memoryStatusTask == nil else { return }

        refreshMemoryStatus()
        memoryStatusTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.refreshMemoryStatusAndUpdateFooter()
            }
        }
    }

    private func refreshMemoryStatusAndUpdateFooter() {
        refreshMemoryStatus()
        updateStatus()
    }

    private func refreshMemoryStatus() {
        memoryStatusText = ProcessMemoryFormatter.label(for: ProcessMemorySampler.currentUsage())
    }

    private func updateStatus(refreshesMemory: Bool = false) {
        if refreshesMemory {
            refreshMemoryStatus()
        }

        guard AppSettings.indexedRootsConfigured(defaults: defaults) else {
            countLabel.stringValue = "0 shown / 0 matches • 0 indexed • 0 ms"
            statusLabel.stringValue = "Setup needed • Choose what AllTheThings can search • \(memoryStatusText)"
            return
        }

        let shownCount = results.count
        let indexed = indexStats.indexedCount.formatted()
        let total = totalMatches.formatted()
        let milliseconds = Int((queryElapsed * 1_000).rounded())
        countLabel.stringValue = "\(shownCount.formatted()) shown / \(total) matches • \(indexed) indexed • \(milliseconds) ms"

        statusLabel.stringValue = "\(indexStatusText()) • \(memoryStatusText)"
    }

    private func indexStatusText() -> String {
        if indexedRoots.isEmpty {
            return "No folders"
        }

        switch indexStats.phase {
        case .idle:
            return indexStats.status
        case .loading:
            return "Loading • \(indexStats.status)"
        case .scanning:
            return "Indexing \(indexStats.discoveredCount.formatted()) discovered • \(indexStats.searchableCount.formatted()) searchable"
        case .optimizing:
            return "\(indexStats.status) • \(indexStats.searchableCount.formatted()) searchable"
        case .saving:
            return "Saving index • \(indexStats.searchableCount.formatted()) searchable"
        case .ready:
            return "Ready • \(indexStats.status)"
        case .failed:
            return indexStats.status
        }
    }

    private func updateActionButtons() {
        let enabled = !selectedRecords().isEmpty
        openButton.isEnabled = enabled
        revealButton.isEnabled = enabled
        copyButton.isEnabled = enabled
        reindexButton.isEnabled = AppSettings.indexedRootsConfigured(defaults: defaults) && !indexedRoots.isEmpty
    }

    private func selectedRecord() -> FileRecord? {
        selectedRecords().first
    }

    private func selectedRecords() -> [FileRecord] {
        tableView.selectedRowIndexes.compactMap { row in
            guard row >= 0, row < results.count else { return nil }
            return results[row].record
        }
    }

    private func highlightedName(_ name: String) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: name, attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
        ])

        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard highlightsSearchText, let token = FuzzyMatcher.primaryHighlightToken(for: query) else {
            return attributed
        }

        let normalizedName = FuzzyMatcher.normalize(name)
        if let range = normalizedName.range(of: token) {
            let lower = normalizedName.distance(from: normalizedName.startIndex, to: range.lowerBound)
            let upper = normalizedName.distance(from: normalizedName.startIndex, to: range.upperBound)
            attributed.addAttributes([
                .foregroundColor: highlightTextColor(),
                .font: NSFont.systemFont(ofSize: 12, weight: .bold)
            ], range: NSRange(location: lower, length: upper - lower))
        }

        return attributed
    }

    private func highlightTextColor() -> NSColor {
        AppTheme.isDarkAppearance(for: view) ? .systemYellow : .systemOrange
    }

    private func sortSpec(for descriptor: NSSortDescriptor) -> SortSpec {
        guard
            let key = descriptor.key,
            let column = Column(rawValue: key)
        else {
            return sortSpec
        }

        return SortSpec(column: column.sortColumn, ascending: descriptor.ascending)
    }

    private func sortDescriptor(for spec: SortSpec) -> NSSortDescriptor {
        let column = Column.column(for: spec.column) ?? .name
        return NSSortDescriptor(key: column.rawValue, ascending: spec.ascending)
    }

    private func insertVisibleColumn(_ column: Column) {
        let identifier = NSUserInterfaceItemIdentifier(column.rawValue)
        guard tableView.tableColumn(withIdentifier: identifier) == nil else {
            return
        }

        tableView.addTableColumn(makeTableColumn(for: column))

        guard
            let fromIndex = tableView.tableColumns.firstIndex(where: { $0.identifier == identifier }),
            let toIndex = Column.allCases.filter({ visibleColumns.contains($0) }).firstIndex(of: column),
            fromIndex != toIndex
        else {
            return
        }

        tableView.moveColumn(fromIndex, toColumn: toIndex)
    }

    private func removeVisibleColumn(_ column: Column) {
        guard let tableColumn = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue)) else {
            return
        }

        tableView.removeTableColumn(tableColumn)
    }

    private func applySortFallbackIfNeeded(afterHiding column: Column) {
        guard column.sortColumn == sortSpec.column else { return }

        sortSpec = Self.defaultSortSpec
        tableView.sortDescriptors = [sortDescriptor(for: sortSpec)]
        saveSortSpec()
        scheduleSearch(force: true)
    }

    @objc private func addScope(_ sender: Any?) {
        presentIndexedFolderChooser(prompt: "Index")
    }

    private func presentIndexedFolderChooser(prompt: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = prompt

        guard panel.runModal() == .OK else { return }

        let existing = Set(indexedRoots.map { $0.standardizedFileURL.path })
        let additions = panel.urls
            .map(\.standardizedFileURL)
            .filter { !existing.contains($0.path) }

        guard !additions.isEmpty else { return }
        indexedRoots.append(contentsOf: additions)
        saveRoots()
        didRequestInitialSnapshotLoad = true
        didRequestInitialRebuild = true
        startWatchingIfNeeded()
        index.replaceRootsAndRebuild(indexedRoots)
        updateSetupSuggestions()
    }

    @objc private func reindex(_ sender: Any?) {
        guard AppSettings.indexedRootsConfigured(defaults: defaults), !indexedRoots.isEmpty else { return }
        didRequestInitialSnapshotLoad = true
        didRequestInitialRebuild = true
        index.replaceRootsAndRebuild(indexedRoots)
    }

    @objc private func searchFieldDidChange(_ sender: NSSearchField) {
        scheduleSearch()
    }

    @objc private func toggleColumnVisibility(_ sender: NSMenuItem) {
        guard
            let rawColumn = sender.representedObject as? String,
            let column = Column(rawValue: rawColumn),
            column != .name
        else {
            return
        }

        if visibleColumns.contains(column) {
            visibleColumns.remove(column)
            removeVisibleColumn(column)
            applySortFallbackIfNeeded(afterHiding: column)
        } else {
            visibleColumns.insert(column)
            insertVisibleColumn(column)
        }

        saveVisibleColumns()
    }

    @objc private func openSelected(_ sender: Any?) {
        guard let record = selectedRecord() else { return }
        NSWorkspace.shared.open(record.url)
    }

    @objc private func openSelectedWithApplication(_ sender: NSMenuItem) {
        guard
            let applicationURL = sender.representedObject as? URL,
            !selectedRecords().isEmpty
        else {
            return
        }

        openSelectedRecords(with: applicationURL)
    }

    @objc private func openSelectedWithOtherApplication(_ sender: Any?) {
        guard !selectedRecords().isEmpty else { return }

        let panel = NSOpenPanel()
        panel.title = "Choose Application"
        panel.prompt = "Open"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let applicationURL = panel.url else { return }
            self?.openSelectedRecords(with: applicationURL)
        }

        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func openSelectedRecords(with applicationURL: URL) {
        let urls = selectedRecords().map(\.url)
        guard !urls.isEmpty else { return }

        NSWorkspace.shared.open(
            urls,
            withApplicationAt: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            if let error {
                self?.presentError("Could not open item.", informativeText: error.localizedDescription)
            }
        }
    }

    @objc private func revealSelected(_ sender: Any?) {
        let urls = selectedRecords().map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func moveSelectedToTrash(_ sender: Any?) {
        let records = selectedRecords()
        guard !records.isEmpty else { return }

        var changedPaths: [String] = []
        for record in records {
            do {
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: record.url, resultingItemURL: &trashedURL)
                changedPaths.append(record.path)
            } catch {
                presentError("Could not move item to Trash.", informativeText: error.localizedDescription)
                break
            }
        }

        if !changedPaths.isEmpty {
            playMascotTransient(.fileChanged)
            index.refresh(paths: changedPaths)
            scheduleSearch(force: true)
        }
    }

    @objc private func getInfoSelected(_ sender: Any?) {
        guard let record = selectedRecord() else { return }
        let path = appleScriptStringLiteral(record.path)
        let source = """
        tell application "Finder"
            activate
            open information window of (POSIX file "\(path)" as alias)
        end tell
        """

        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            presentError("Could not show item info.", informativeText: error.description)
        }
    }

    @objc private func renameSelected(_ sender: Any?) {
        guard let record = selectedRecord() else { return }

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = record.name

        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.informativeText = record.directoryPath
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.rename(record: record, to: field.stringValue)
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func rename(record: FileRecord, to rawName: String) {
        let newName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != record.name else { return }
        guard !newName.contains("/") else {
            presentError("Could not rename item.", informativeText: "Names cannot contain slashes.")
            return
        }

        let destination = URL(fileURLWithPath: record.directoryPath, isDirectory: true).appendingPathComponent(newName)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            presentError("Could not rename item.", informativeText: "An item named \"\(newName)\" already exists.")
            return
        }

        do {
            try FileManager.default.moveItem(at: record.url, to: destination)
            playMascotTransient(.fileChanged)
            index.refresh(paths: [record.path, destination.path])
            scheduleSearch(force: true)
        } catch {
            presentError("Could not rename item.", informativeText: error.localizedDescription)
        }
    }

    @objc private func quickLookSelected(_ sender: Any?) {
        let paths = selectedRecords().map(\.path)
        guard !paths.isEmpty else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p"] + paths

        do {
            try process.run()
        } catch {
            presentError("Could not Quick Look item.", informativeText: error.localizedDescription)
        }
    }

    @objc private func openTerminalHere(_ sender: NSMenuItem) {
        guard
            let serviceTitle = sender.representedObject as? String,
            let record = selectedRecord()
        else {
            return
        }

        let directoryPath = terminalDirectoryPath(for: record)
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString(directoryPath, forType: .string)
        pasteboard.setPropertyList([directoryPath], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))

        if !NSPerformService(serviceTitle, pasteboard) {
            presentError("Could not open terminal here.", informativeText: "\(serviceTitle) is not available from Services.")
        }
    }

    @objc private func copy(_ sender: Any?) {
        copySelectedFiles()
    }

    private func copySelectedFiles() {
        let records = selectedRecords()
        guard !records.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(records.map { $0.url as NSURL })
        pasteboard.setString(records.map(\.path).joined(separator: "\n"), forType: .string)
    }

    @objc private func copySelectedPath(_ sender: Any?) {
        let records = selectedRecords()
        guard !records.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(records.map(\.path).joined(separator: "\n"), forType: .string)
    }

    private func terminalDirectoryPath(for record: FileRecord) -> String {
        record.isDirectory ? record.path : record.directoryPath
    }

    private func isApplicationInstalled(bundleIdentifiers: [String], fallbackAppNames: [String]) -> Bool {
        for bundleIdentifier in bundleIdentifiers where NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil {
            return true
        }

        let homeApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        let applicationDirectories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeApplications
        ]

        for directory in applicationDirectories {
            for appName in fallbackAppNames {
                let candidate = directory.appendingPathComponent(appName).appendingPathExtension("app")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return true
                }
            }
        }

        return false
    }

    private func appleScriptStringLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func presentError(_ message: String, informativeText: String) {
        playMascotTransient(.error)
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

    private func saveRoots() {
        AppSettings.saveIndexedRoots(indexedRoots, defaults: defaults)
    }

    private func saveSortSpec() {
        defaults.set(sortSpec.column.rawValue, forKey: DefaultsKey.sortColumn)
        defaults.set(sortSpec.ascending, forKey: DefaultsKey.sortAscending)
    }

    private func saveVisibleColumns() {
        let ordered = Column.allCases
            .filter { visibleColumns.contains($0) }
            .map(\.rawValue)
        defaults.set(ordered, forKey: DefaultsKey.visibleColumns)
    }

    private static func loadSortSpec(defaults: UserDefaults) -> SortSpec {
        guard
            let rawColumn = defaults.string(forKey: DefaultsKey.sortColumn),
            let column = SortColumn(rawValue: rawColumn),
            Column.column(for: column) != nil
        else {
            return defaultSortSpec
        }

        let ascending = defaults.object(forKey: DefaultsKey.sortAscending) == nil
            ? defaultSortSpec.ascending
            : defaults.bool(forKey: DefaultsKey.sortAscending)
        return SortSpec(column: column, ascending: ascending)
    }

    private static func loadVisibleColumns(defaults: UserDefaults) -> Set<Column> {
        guard let saved = defaults.array(forKey: DefaultsKey.visibleColumns) as? [String] else {
            return defaultVisibleColumns
        }

        var columns = Set(saved.compactMap(Column.init(rawValue:)))
        columns.insert(.name)
        return columns
    }

    private static func normalizedSortSpec(_ spec: SortSpec, visibleColumns: Set<Column>) -> SortSpec {
        guard let column = Column.column(for: spec.column), visibleColumns.contains(column) else {
            return defaultSortSpec
        }

        return spec
    }
}

private final class ClickableMascotView: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

private final class IndexingSetupOverlayView: NSView {
    let startIndexingButton = NSButton()
    let chooseIndexedFoldersButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        isHidden = true

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "Get started")
        iconView.contentTintColor = .secondaryLabelColor

        let titleLabel = NSTextField(labelWithString: "Get Started")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center

        let detailLabel = NSTextField(labelWithString: """
        Indexing lets AllTheThings discover files in selected folders,
        so filename and path searches can show results.
        Start with the default folders, or choose your own.
        """)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 3

        let buttonStack = NSStackView(views: [
            Self.configureActionButton(startIndexingButton, title: "Start Indexing", symbolName: "play.circle"),
            Self.configureActionButton(chooseIndexedFoldersButton, title: "Choose Folders...", symbolName: "folder")
        ])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8

        let stack = NSStackView(views: [iconView, titleLabel, detailLabel, buttonStack])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),

            iconView.widthAnchor.constraint(equalToConstant: 34),
            iconView.heightAnchor.constraint(equalToConstant: 34),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 620)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @discardableResult
    private static func configureActionButton(_ button: NSButton, title: String, symbolName: String) -> NSButton {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = title
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 13, weight: .regular)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }
}

private final class SetupSuggestionPanelView: NSView {
    let enableGlobalHotKeyButton = NSButton()
    let chooseGlobalHotKeyButton = NSButton()
    let openFullDiskAccessButton = NSButton()
    let dismissGlobalHotKeyButton = NSButton()
    let dismissFullDiskAccessButton = NSButton()

    private let globalHotKeyRow = NSView()
    private let fullDiskAccessRow = NSView()
    private let globalHotKeySeparator = SetupSuggestionSeparatorView()
    private let globalHotKeyDetailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let globalHotKeyTitleLabel = Self.makeTitleLabel("Global search hotkey")
        let fullDiskAccessTitleLabel = Self.makeTitleLabel("Full Disk Access")
        let fullDiskAccessDetailLabel = Self.makeDetailLabel(
            "Grant access before indexing protected folders to avoid macOS prompts."
        )
        Self.configureSuggestionRow(
            globalHotKeyRow,
            symbolName: "keyboard",
            titleLabel: globalHotKeyTitleLabel,
            detailLabel: globalHotKeyDetailLabel,
            buttons: [
                Self.configureActionButton(enableGlobalHotKeyButton, title: "Enable", symbolName: "checkmark.circle"),
                Self.configureActionButton(chooseGlobalHotKeyButton, title: "Customize", symbolName: "slider.horizontal.3"),
                Self.configureActionButton(dismissGlobalHotKeyButton, title: "Not Now", symbolName: "xmark")
            ]
        )
        Self.configureSuggestionRow(
            fullDiskAccessRow,
            symbolName: "externaldrive.badge.checkmark",
            titleLabel: fullDiskAccessTitleLabel,
            detailLabel: fullDiskAccessDetailLabel,
            buttons: [
                Self.configureActionButton(openFullDiskAccessButton, title: "Open Settings", symbolName: "gearshape"),
                Self.configureActionButton(dismissFullDiskAccessButton, title: "Not Now", symbolName: "xmark")
            ]
        )

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        updateThemeColors()

        let rowsStack = NSStackView(views: [
            globalHotKeyRow,
            globalHotKeySeparator,
            fullDiskAccessRow
        ])
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.spacing = 5
        rowsStack.detachesHiddenViews = true

        addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            rowsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            rowsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            rowsStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            globalHotKeySeparator.heightAnchor.constraint(equalToConstant: 2)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateThemeColors()
    }

    func update(
        hotKey: GlobalHotKey,
        needsGlobalHotKey: Bool,
        needsFullDiskAccess: Bool
    ) {
        globalHotKeyDetailLabel.stringValue = "Use \(hotKey.displayString) to open search from anywhere."
        globalHotKeyRow.isHidden = !needsGlobalHotKey
        fullDiskAccessRow.isHidden = !needsFullDiskAccess
        globalHotKeySeparator.isHidden = !needsGlobalHotKey || !needsFullDiskAccess
        isHidden = !needsGlobalHotKey && !needsFullDiskAccess
    }

    private func updateThemeColors() {
        layer?.backgroundColor = AppTheme.resolvedCGColor(NSColor.controlBackgroundColor, for: self)
        layer?.borderColor = AppTheme.resolvedCGColor(NSColor.separatorColor, for: self)
    }

    private static func configureSuggestionRow(
        _ row: NSView,
        symbolName: String,
        titleLabel: NSTextField,
        detailLabel: NSTextField,
        buttons: [NSButton]
    ) {
        row.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: titleLabel.stringValue)
        iconView.contentTintColor = .secondaryLabelColor

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3

        let buttonStack = NSStackView(views: buttons)
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8

        row.addSubview(iconView)
        row.addSubview(textStack)
        row.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 46),

            iconView.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -16),

            buttonStack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            buttonStack.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
    }

    private static func makeTitleLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private static func makeDetailLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    @discardableResult
    private static func configureActionButton(_ button: NSButton, title: String, symbolName: String) -> NSButton {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = title
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12, weight: .regular)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }
}

private final class SetupSuggestionSeparatorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        updateThemeColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateThemeColors()
    }

    private func updateThemeColors() {
        layer?.backgroundColor = AppTheme.resolvedCGColor(NSColor.labelColor.withAlphaComponent(0.28), for: self)
    }
}

private final class SearchCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock {
            cancelled
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
        }
    }
}

private final class FileTableView: NSTableView {
    var copyAction: (() -> Void)?
    var copyPathAction: (() -> Void)?

    @objc func copy(_ sender: Any?) {
        copyAction?()
    }

    override func rightMouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: location)
        if clickedRow >= 0, !selectedRowIndexes.contains(clickedRow) {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }

        super.rightMouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard
            event.modifierFlags.contains(.command),
            event.charactersIgnoringModifiers?.lowercased() == "c"
        else {
            super.keyDown(with: event)
            return
        }

        if event.modifierFlags.contains(.option) {
            copyPathAction?()
        } else {
            copyAction?()
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
