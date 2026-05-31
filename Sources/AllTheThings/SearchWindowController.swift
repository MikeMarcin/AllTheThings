import AppKit
import ATTCore
import QuartzCore
import UniformTypeIdentifiers

enum AppRuntimeStatusFormatter {
    static func windowTitle(version: String?, build: String?) -> String {
        switch (version, build) {
        case let (version?, _) where !version.isEmpty:
            return "AllTheThings \(version)"
        case let (_, build?) where !build.isEmpty:
            return "AllTheThings \(build)"
        default:
            return "AllTheThings"
        }
    }

    static func operationElapsed(_ elapsed: TimeInterval) -> String {
        let totalSeconds = max(Int(elapsed.rounded()), 0)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return "\(hours)h \(String(format: "%02dm", minutes))"
        }
        if minutes > 0 {
            return "\(minutes)m \(String(format: "%02ds", seconds))"
        }
        return "\(seconds)s"
    }

    static func catchUpStatus(elapsed: TimeInterval) -> String {
        "Catching up changes • \(operationElapsed(elapsed))"
    }
}

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
        window.title = Self.windowTitle()
        window.titlebarAppearsTransparent = true
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.isRestorable = false
        window.contentMinSize = WindowLayout.minimumContentSize
        window.contentViewController = viewController
        window.center()
        super.init(window: window)
    }

    private static func windowTitle() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return AppRuntimeStatusFormatter.windowTitle(version: version, build: build)
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
        case match
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
            case .match: "Match"
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
            case .match: 40
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
            case .match: .relevance
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
            case .match: "Match Quality"
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
                .match
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

    private struct ExplanationCacheKey: Hashable {
        let query: String
        let recordID: UInt64
    }

    private enum SearchScheduling {
        static let unoptimizedIndexingSearchBudget: TimeInterval = 0.75
    }

    private final class SearchBudgetTimeout: @unchecked Sendable {
        private let lock = NSLock()
        private var timedOut = false

        var didTimeOut: Bool {
            lock.withLock {
                timedOut
            }
        }

        func markTimedOut() {
            lock.withLock {
                timedOut = true
            }
        }
    }

    private enum MascotFlightPlayback {
        case animation(OperationMascotAnimation)
        case standalone(OperationMascotStandaloneClip)

        var frameCount: Int {
            switch self {
            case let .animation(animation): animation.frameCount
            case let .standalone(clip): clip.frameCount
            }
        }

        var framesPerSecond: Double {
            switch self {
            case let .animation(animation): animation.framesPerSecond
            case let .standalone(clip): clip.framesPerSecond
            }
        }

        var loops: Bool {
            switch self {
            case let .animation(animation): animation.loops
            case let .standalone(clip): clip.loops
            }
        }

        var startsFromFirstFrame: Bool {
            switch self {
            case .animation: false
            case .standalone: true
            }
        }

        @MainActor
        func frame(from spriteSheet: MascotSpriteSheet, index: Int) -> NSImage? {
            switch self {
            case let .animation(animation):
                return spriteSheet.frame(for: animation, index: index)
            case let .standalone(clip):
                return spriteSheet.frame(for: clip, index: index)
            }
        }
    }

    private let index: FileIndex
    private let fseventCursorStore = FSEventCursorStore.default
    private lazy var watcher = FileSystemWatcher(cursorStore: fseventCursorStore)
    private lazy var fseventReconciler = FSEventReconciliationCoordinator(cursorStore: fseventCursorStore)
    private let searchQueue = DispatchQueue(label: "att.search", qos: .userInitiated)
    private let explanationQueue = DispatchQueue(label: "att.search.explain", qos: .utility)
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
    private let mascotFlightImageView = NSImageView()

    private var results: [SearchResult] = []
    private var explanationCache: [ExplanationCacheKey: MatchExplanation] = [:]
    private var indexStats: IndexStats
    private var totalMatches = 0
    private var queryElapsed: TimeInterval = 0
    private var initialQueryElapsed: TimeInterval?
    private var isRefiningSearchResults = false
    private var hasFinalSearchTiming = false
    private var activeSearchStartedAt: Date?
    private var pendingSearchInputStartedAt: Date?
    private var queryGeneration: UInt64 = 0
    private var activeSearchToken: SearchCancellationToken?
    private var explanationGeneration: UInt64 = 0
    private var activeExplanationToken = SearchCancellationToken()
    private var pendingExplanationKeys = Set<ExplanationCacheKey>()
    private var scheduledSearchSignature: SearchSignature?
    private var displayedSearchSignature: SearchSignature?
    private var sortSpec: SortSpec
    private var visibleColumns: Set<Column>
    private var indexedRoots: [URL]
    private var pendingEventPaths = Set<String>()
    private var pendingRecursiveEventPaths = Set<String>()
    private var eventDebounce: DispatchWorkItem?
    private var activeFSEventReplay: FSEventHistoryReplayCancellable?
    private var activeFSEventReconciliationID: UUID?
    private var fseventCatchUpStartedAt: Date?
    private var memoryStatusTask: Task<Void, Never>?
    private var memoryStatusText = ProcessMemoryFormatter.label(for: ProcessMemorySampler.currentUsage())
    private var mascotCoordinator: OperationMascotCoordinator?
    private var expandedMascotCoordinator: OperationMascotCoordinator?
    private var loadingMascotCoordinator: OperationMascotCoordinator?
    private var setupMascotCoordinator: StandaloneMascotCoordinator?
    private var expandedMascotLeadingConstraint: NSLayoutConstraint?
    private var expandedMascotImageBottomConstraint: NSLayoutConstraint?
    private var mascotFlightPlayback: MascotFlightPlayback?
    private var mascotFlightFallbackImage: NSImage?
    private var mascotFlightFrameIndex = 0
    private nonisolated(unsafe) var mascotFlightFrameTimer: Timer?
    private var isExpandedMascotVisible = false
    private var isMascotFlightInProgress = false
    private var isSetupMascotTuckInProgress = false
    private var loadingOverlaySawActiveLoad = false
    private var userExpandedMascot = false
    private var userCollapsedExpandedMascotDuringOperation = false
    private var wasImportantMascotOperationActive = false
    private var didRequestInitialSnapshotLoad = false
    private var didRequestInitialRebuild = false
    private var highlightsSearchText: Bool
    private var showsHiddenFiles: Bool
    private var appFontFamilyName: String?
    private var appFontSize: CGFloat

    private enum DefaultsKey {
        static let sortColumn = "ATTSortColumn"
        static let sortAscending = "ATTSortAscending"
        static let visibleColumns = "ATTVisibleColumns"
        static let visibleColumnsSchema = "ATTVisibleColumnsSchema"
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
        self.appFontFamilyName = AppSettings.appFontFamilyName(defaults: defaults)
        self.appFontSize = AppSettings.appFontSize(defaults: defaults)
        super.init(nibName: nil, bundle: nil)
    }

    deinit {
        activeFSEventReplay?.cancel()
        memoryStatusTask?.cancel()
        activeExplanationToken.cancel()
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
        index.onBackgroundReconciliationRequested = { @MainActor @Sendable [weak self] roots in
            self?.runFSEventsBackedReconciliation(roots: roots)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange(_:)),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appFontDidChange(_:)),
            name: AppSettings.appFontDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(matchColorsDidChange(_:)),
            name: AppSettings.matchColorsDidChangeNotification,
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
        updateScanSnapshotPublishingPreference()
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

        let result = results[row]
        let record = result.record

        if column == .match {
            let cell = makeMatchCell(for: tableColumn.identifier)
            configureMatchCell(cell, explanation: displayExplanation(for: result, schedulesAsyncExplanation: true))
            return cell
        }

        let cell = makeCell(for: tableColumn.identifier)
        let textField = cell.textField
        textField?.font = AppSettings.appFont(defaults: defaults)

        switch column {
        case .match:
            break
        case .name:
            textField?.attributedStringValue = highlightedText(
                record.name,
                field: .name,
                explanation: displayExplanation(for: result, schedulesAsyncExplanation: highlightsSearchText),
                baseAttributes: [
                    .foregroundColor: NSColor.labelColor,
                    .font: AppSettings.appFont(defaults: defaults, weight: .semibold)
                ]
            )
            textField?.lineBreakMode = .byTruncatingMiddle
        case .path:
            textField?.attributedStringValue = highlightedPath(
                record.directoryPath,
                explanation: displayExplanation(for: result, schedulesAsyncExplanation: highlightsSearchText)
            )
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
        markSearchInputStarted()
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
        footer.edgeInsets = NSEdgeInsets(top: 2, left: 14, bottom: 2, right: 14)
        footer.translatesAutoresizingMaskIntoConstraints = false

        countLabel.textColor = .secondaryLabelColor
        countLabel.lineBreakMode = .byTruncatingTail
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
        applyFontSettings()

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

    private func applyFontSettings() {
        let baseSize = AppSettings.appFontSize(defaults: defaults)
        searchField.font = AppSettings.appFont(defaults: defaults, sizeDelta: 4)
        tableView.rowHeight = max(20, baseSize + 8)
        countLabel.font = AppSettings.appFont(defaults: defaults)
        statusLabel.font = AppSettings.appFont(defaults: defaults)
        loadingLabel.font = AppSettings.appFont(defaults: defaults, sizeDelta: 2, weight: .medium)
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
            mascotSlotView.widthAnchor.constraint(equalToConstant: OperationMascotCoordinator.statusDisplaySize),
            mascotSlotView.heightAnchor.constraint(equalToConstant: OperationMascotCoordinator.footerSlotHeight),
            mascotImageView.centerXAnchor.constraint(equalTo: mascotSlotView.centerXAnchor),
            mascotImageView.bottomAnchor.constraint(equalTo: mascotSlotView.bottomAnchor)
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
        setupMascotCoordinator = StandaloneMascotCoordinator(
            imageView: indexingSetupOverlay.mascotImageView,
            clip: .introWelcome,
            displaySize: OperationMascotCoordinator.heroDisplaySize
        )

        mascotFlightImageView.imageScaling = .scaleProportionallyUpOrDown
        mascotFlightImageView.imageAlignment = .alignCenter
        mascotFlightImageView.wantsLayer = true
        mascotFlightImageView.layer?.masksToBounds = false
        mascotFlightImageView.isHidden = true
        mascotFlightImageView.setAccessibilityRole(.image)
        mascotFlightImageView.setAccessibilityLabel("Nib moving into place")

        view.addSubview(indexingSetupOverlay)
        view.addSubview(mascotFlightImageView)
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

        let setupOverlayVisible = needsIndexingSetup || isSetupMascotTuckInProgress
        indexingSetupOverlay.isHidden = !setupOverlayVisible
        indexingSetupOverlay.setMascotVisible(setupOverlayVisible && !isSetupMascotTuckInProgress)
        setupMascotCoordinator?.setActive(setupOverlayVisible && !isSetupMascotTuckInProgress)
        setupSuggestionPanel.update(
            hotKey: AppSettings.globalSearchHotKey(defaults: defaults),
            needsGlobalHotKey: needsGlobalHotKey,
            needsFullDiskAccess: needsFullDiskAccess
        )
        updateMascotPlacementVisibility()
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
        beginSetupMascotTuckAwayIfPossible()
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

    @discardableResult
    private func beginSetupMascotTuckAwayIfPossible() -> Bool {
        guard
            !indexingSetupOverlay.isHidden,
            !isMascotFlightInProgress,
            !isSetupMascotTuckInProgress,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            return false
        }

        view.layoutSubtreeIfNeeded()
        guard let currentImage = indexingSetupOverlay.mascotImageView.image else {
            return false
        }

        let startFrame = indexingSetupOverlay.mascotImageView.convert(indexingSetupOverlay.mascotImageView.bounds, to: view)
        let targetFrame = setupMascotTuckTargetFrame()
        guard !startFrame.isEmpty, !targetFrame.isEmpty else {
            return false
        }

        isSetupMascotTuckInProgress = true
        setupMascotCoordinator?.setActive(false)
        indexingSetupOverlay.setMascotVisible(false)

        return beginMascotFlight(
            image: currentImage,
            startFrame: startFrame,
            targetFrame: targetFrame,
            duration: 0.64,
            playback: .standalone(.flydown)
        ) {
            self.isSetupMascotTuckInProgress = false
            self.indexingSetupOverlay.setMascotVisible(true)
            self.updateSetupSuggestions()
            self.updateExpandedMascotForOperation(animated: false)
            self.updateMascotPlacementVisibility()
        }
    }

    @discardableResult
    private func beginMascotFlight(
        image: NSImage,
        startFrame: NSRect,
        targetFrame: NSRect,
        duration: TimeInterval,
        playback: MascotFlightPlayback? = nil,
        completion: @escaping () -> Void
    ) -> Bool {
        guard !isMascotFlightInProgress, !startFrame.isEmpty, !targetFrame.isEmpty else {
            return false
        }

        isMascotFlightInProgress = true
        mascotFlightImageView.removeFromSuperview()
        view.addSubview(mascotFlightImageView)
        mascotFlightImageView.image = image
        mascotFlightImageView.frame = startFrame
        mascotFlightImageView.alphaValue = 1
        mascotFlightImageView.isHidden = false
        startMascotFlightFramePlayback(playback, fallbackImage: image)
        updateMascotPlacementVisibility()
        view.layoutSubtreeIfNeeded()

        guard let layer = mascotFlightImageView.layer else {
            finishMascotFlight(completion: completion)
            return true
        }

        let startPosition = layer.position
        let startBounds = layer.bounds

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mascotFlightImageView.frame = targetFrame
        view.layoutSubtreeIfNeeded()
        let targetPosition = layer.position
        let targetBounds = layer.bounds
        CATransaction.commit()

        let positionAnimation = CABasicAnimation(keyPath: "position")
        positionAnimation.fromValue = startPosition
        positionAnimation.toValue = targetPosition

        let boundsAnimation = CABasicAnimation(keyPath: "bounds")
        boundsAnimation.fromValue = startBounds
        boundsAnimation.toValue = targetBounds

        let flightAnimation = CAAnimationGroup()
        flightAnimation.animations = [positionAnimation, boundsAnimation]
        flightAnimation.duration = duration
        flightAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        flightAnimation.fillMode = .removed
        flightAnimation.isRemovedOnCompletion = true
        layer.add(flightAnimation, forKey: "mascotFlight")

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.finishMascotFlight(completion: completion)
        }

        return true
    }

    private func finishMascotFlight(completion: () -> Void) {
        mascotFlightFrameTimer?.invalidate()
        mascotFlightFrameTimer = nil
        mascotFlightPlayback = nil
        mascotFlightFallbackImage = nil
        mascotFlightImageView.layer?.removeAnimation(forKey: "mascotFlight")
        mascotFlightImageView.isHidden = true
        mascotFlightImageView.image = nil
        isMascotFlightInProgress = false
        completion()
    }

    private func startMascotFlightFramePlayback(
        _ playback: MascotFlightPlayback?,
        fallbackImage: NSImage
    ) {
        mascotFlightFrameTimer?.invalidate()
        mascotFlightFrameTimer = nil
        mascotFlightPlayback = playback
        mascotFlightFallbackImage = fallbackImage

        guard
            let playback,
            playback.frameCount > 1,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            mascotFlightImageView.image = fallbackImage
            return
        }

        mascotFlightFrameIndex = playback.startsFromFirstFrame
            ? 0
            : Int(Date().timeIntervalSinceReferenceDate * playback.framesPerSecond) % playback.frameCount
        renderMascotFlightFrame()

        let frameInterval = 1 / playback.framesPerSecond
        let timer = Timer(timeInterval: frameInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.advanceMascotFlightFrame()
            }
        }
        timer.tolerance = min(0.03, frameInterval * 0.2)
        RunLoop.main.add(timer, forMode: .common)
        mascotFlightFrameTimer = timer
    }

    private func advanceMascotFlightFrame() {
        guard let playback = mascotFlightPlayback else { return }

        if playback.loops {
            mascotFlightFrameIndex = (mascotFlightFrameIndex + 1) % playback.frameCount
        } else {
            mascotFlightFrameIndex = min(mascotFlightFrameIndex + 1, playback.frameCount - 1)
        }
        renderMascotFlightFrame()
    }

    private func renderMascotFlightFrame() {
        guard let playback = mascotFlightPlayback else {
            mascotFlightImageView.image = mascotFlightFallbackImage
            return
        }

        mascotFlightImageView.image = playback.frame(
            from: MascotSpriteSheet.shared,
            index: mascotFlightFrameIndex
        ) ?? mascotFlightFallbackImage
    }

    private func setupMascotTuckTargetFrame() -> NSRect {
        view.layoutSubtreeIfNeeded()
        let footerFrame = mascotImageView.convert(mascotImageView.bounds, to: view)
        let targetSize = OperationMascotCoordinator.expandedDisplaySize
        let targetBottom = footerFrame.minY + expandedMascotImageBottomOffset(for: targetSize)
        return NSRect(
            x: ExpandedMascotLayout.leadingOffset,
            y: targetBottom - targetSize,
            width: targetSize,
            height: targetSize
        )
    }

    private func configureLoadingOverlay() {
        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false

        loadingMascotImageView.translatesAutoresizingMaskIntoConstraints = false
        loadingMascotCoordinator = OperationMascotCoordinator(
            imageView: loadingMascotImageView,
            displaySize: OperationMascotCoordinator.heroDisplaySize
        )

        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
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
        textField.font = AppSettings.appFont(defaults: defaults)
        cell.addSubview(textField)
        cell.textField = textField

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])

        return cell
    }

    private func makeMatchCell(for identifier: NSUserInterfaceItemIdentifier) -> MatchIconCellView {
        if let reusable = tableView.makeView(withIdentifier: identifier, owner: self) as? MatchIconCellView {
            return reusable
        }

        let cell = MatchIconCellView()
        cell.identifier = identifier
        return cell
    }

    private func configureMatchCell(_ cell: MatchIconCellView, explanation: MatchExplanation?) {
        guard let explanation else {
            cell.configure(icon: nil, color: .clear, placard: nil)
            return
        }

        let label = matchLabel(for: explanation.matchClass)
        let color = matchColor(for: explanation.quality)
        let placard = MatchPlacard(
            title: "\(label) match",
            scoreText: "Score \(explanation.score.formatted())",
            reason: explanation.reason,
            color: color
        )
        cell.configure(
            icon: matchIcon(for: explanation.matchClass, accessibilityDescription: label),
            color: color,
            placard: placard
        )
    }

    private func displayExplanation(
        for result: SearchResult,
        schedulesAsyncExplanation: Bool
    ) -> MatchExplanation? {
        let query = currentSearchText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return result.match
        }

        let key = ExplanationCacheKey(query: query, recordID: result.record.id)
        if let cached = explanationCache[key] {
            return cached
        }

        if schedulesAsyncExplanation {
            scheduleExplanation(for: result.record, query: query, key: key)
        }

        return result.match
    }

    private func scheduleVisibleExplanations() {
        let query = currentSearchText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        let visibleRows = tableView.rows(in: tableView.visibleRect)
        guard visibleRows.location != NSNotFound, visibleRows.length > 0 else { return }

        let end = min(results.count, visibleRows.location + visibleRows.length)
        guard visibleRows.location < end else { return }

        for row in visibleRows.location..<end {
            let record = results[row].record
            let key = ExplanationCacheKey(query: query, recordID: record.id)
            scheduleExplanation(for: record, query: query, key: key)
        }
    }

    private func scheduleExplanation(for record: FileRecord, query: String, key: ExplanationCacheKey) {
        guard displayedSearchSignature?.query == query else { return }
        guard explanationCache[key] == nil, !pendingExplanationKeys.contains(key) else { return }

        pendingExplanationKeys.insert(key)
        let generation = explanationGeneration
        let token = activeExplanationToken
        explanationQueue.async { [weak self] in
            guard !token.isCancelled else { return }
            let explanation = FuzzyMatcher.explain(record: record, query: query)
            guard !token.isCancelled else { return }

            DispatchQueue.main.async { [weak self] in
                guard
                    let self,
                    self.explanationGeneration == generation,
                    self.activeExplanationToken === token,
                    self.displayedSearchSignature?.query == query
                else {
                    return
                }

                self.pendingExplanationKeys.remove(key)
                guard let explanation else { return }
                self.explanationCache[key] = explanation
                self.reloadVisibleRows(for: record.id)
            }
        }
    }

    private func reloadVisibleRows(for recordID: UInt64) {
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        guard visibleRows.location != NSNotFound, visibleRows.length > 0 else { return }

        let end = min(results.count, visibleRows.location + visibleRows.length)
        guard visibleRows.location < end else { return }

        var rowIndexes = IndexSet()
        for row in visibleRows.location..<end where results[row].record.id == recordID {
            rowIndexes.insert(row)
        }

        guard !rowIndexes.isEmpty else { return }
        tableView.reloadData(
            forRowIndexes: rowIndexes,
            columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
        )
    }

    private func resetExplanationPipeline(keepingCapacity: Bool = true) {
        activeExplanationToken.cancel()
        activeExplanationToken = SearchCancellationToken()
        explanationGeneration &+= 1
        explanationCache.removeAll(keepingCapacity: keepingCapacity)
        pendingExplanationKeys.removeAll(keepingCapacity: keepingCapacity)
    }

    private func scheduleSearch(force: Bool = false) {
        guard !indexStats.isLoadingSnapshot else { return }

        let request = SearchRequest(query: currentSearchText(), sort: sortSpec, includeHidden: showsHiddenFiles)
        updateScanSnapshotPublishingPreference(for: request)
        let signature = SearchSignature(
            query: request.query,
            sort: request.sort,
            includeHidden: request.includeHidden
        )
        if shouldSuppressEmptySearchDuringIndexing(request: request) {
            suppressEmptySearchDuringIndexing(signature: signature)
            return
        }

        let signatureChanged = signature != scheduledSearchSignature
        guard force || signatureChanged else {
            pendingSearchInputStartedAt = nil
            return
        }

        if activeSearchToken != nil, force, !signatureChanged {
            return
        }

        scheduledSearchSignature = signature

        let redisplaysCurrentSignature = signature == displayedSearchSignature

        activeSearchToken?.cancel()
        let token = SearchCancellationToken()
        activeSearchToken = token
        let searchStartedAt: Date
        if redisplaysCurrentSignature, initialQueryElapsed != nil, !hasFinalSearchTiming {
            searchStartedAt = activeSearchStartedAt ?? Date()
            activeSearchStartedAt = searchStartedAt
            isRefiningSearchResults = true
        } else {
            searchStartedAt = pendingSearchInputStartedAt ?? Date()
            activeSearchStartedAt = searchStartedAt
            initialQueryElapsed = nil
            isRefiningSearchResults = false
            hasFinalSearchTiming = false
        }
        pendingSearchInputStartedAt = nil
        updateMascotPersistentAnimation()

        let queryChanged = displayedSearchSignature?.query != signature.query
        if signature != displayedSearchSignature {
            results = []
            if queryChanged {
                resetExplanationPipeline()
            }
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
        let budgetTimeout = SearchBudgetTimeout()
        let trimmedQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldRunPreviewSearch = !trimmedQuery.isEmpty
            && request.sort.column == .name
            && signature != displayedSearchSignature
        let previewRequest = SearchRequest(
            query: request.query,
            sort: request.sort,
            includeHidden: request.includeHidden,
            mode: .interactivePreview
        )

        searchQueue.async {
            guard !token.isCancelled else {
                DispatchQueue.main.async { [weak self] in
                    self?.clearSearchTokenIfCurrent(token)
                }
                return
            }

            if shouldRunPreviewSearch,
               let previewResponse = index.search(previewRequest, shouldCancel: { token.isCancelled }) {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.queryGeneration == generation, self.activeSearchToken === token else { return }
                    self.applySearchResponse(
                        previewResponse,
                        signature: signature,
                        token: token,
                        searchStartedAt: searchStartedAt,
                        isFinal: false
                    )
                }
            }

            guard !token.isCancelled else {
                DispatchQueue.main.async { [weak self] in
                    self?.clearSearchTokenIfCurrent(token)
                }
                return
            }

            let fullSearchStartedAt = Date()
            guard let response = index.search(request, shouldCancel: {
                if token.isCancelled {
                    return true
                }
                if
                    Self.shouldBudgetSearchDuringIndexing(request: request, stats: index.currentStats()),
                    Date().timeIntervalSince(fullSearchStartedAt) >= SearchScheduling.unoptimizedIndexingSearchBudget
                {
                    budgetTimeout.markTimedOut()
                    return true
                }
                return false
            }) else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.clearSearchTokenIfCurrent(token)
                    if budgetTimeout.didTimeOut, !self.shouldBudgetSearchDuringIndexing(request: request) {
                        self.scheduleSearch(force: true)
                    }
                }
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.queryGeneration == generation, self.activeSearchToken === token else { return }
                self.applySearchResponse(
                    response,
                    signature: signature,
                    token: token,
                    searchStartedAt: searchStartedAt,
                    isFinal: true
                )
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

    private func applySearchResponse(
        _ response: SearchResponse,
        signature: SearchSignature,
        token: SearchCancellationToken,
        searchStartedAt: Date,
        isFinal: Bool
    ) {
        guard activeSearchToken === token else { return }
        let elapsed = max(Date().timeIntervalSince(searchStartedAt), 0)
        if isFinal {
            activeSearchToken = nil
            isRefiningSearchResults = false
            hasFinalSearchTiming = true
            activeSearchStartedAt = nil
        } else {
            initialQueryElapsed = elapsed
            isRefiningSearchResults = true
            hasFinalSearchTiming = false
        }
        if displayedSearchSignature?.query != signature.query {
            resetExplanationPipeline()
        }
        results = response.results
        totalMatches = response.totalMatches
        queryElapsed = elapsed
        displayedSearchSignature = signature
        tableView.reloadData()
        scheduleVisibleExplanations()
        updateStatus(refreshesMemory: isFinal)
        updateLoadingOverlay()
        updateActionButtons()
        updateMascotPersistentAnimation()
    }

    private func clearSearchTokenIfCurrent(_ token: SearchCancellationToken) {
        guard activeSearchToken === token else { return }
        activeSearchToken = nil
        isRefiningSearchResults = false
        activeSearchStartedAt = nil
        updateStatus()
        updateLoadingOverlay()
        updateMascotPersistentAnimation()
    }

    private func suppressEmptySearchDuringIndexing(signature: SearchSignature) {
        scheduledSearchSignature = signature
        if activeSearchToken != nil {
            activeSearchToken?.cancel()
            activeSearchToken = nil
            activeSearchStartedAt = nil
            queryGeneration &+= 1
        }

        if !results.isEmpty || totalMatches != 0 || queryElapsed != 0 || displayedSearchSignature != signature {
            results = []
            if displayedSearchSignature?.query != signature.query {
                resetExplanationPipeline()
            }
            totalMatches = 0
            queryElapsed = 0
            initialQueryElapsed = nil
            isRefiningSearchResults = false
            hasFinalSearchTiming = false
            activeSearchStartedAt = nil
            displayedSearchSignature = signature
            tableView.reloadData()
            updateStatus()
            updateActionButtons()
        }

        updateLoadingOverlay()
        updateMascotPersistentAnimation()
    }

    private func handleStatsChanged(_ stats: IndexStats) {
        let previousStats = indexStats
        let previousPhase = previousStats.phase
        indexStats = stats
        markFSEventBaselineIfNeeded(previous: previousStats, current: stats)
        handleMascotTransition(from: previousPhase, to: stats.phase)
        updateStatus()
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

        if stats.snapshotRevision != previousStats.snapshotRevision {
            scheduleSearch(force: true)
        } else {
            scheduleSearch()
        }
    }

    private func shouldSuppressEmptySearchDuringIndexing(request: SearchRequest, stats: IndexStats? = nil) -> Bool {
        let stats = stats ?? indexStats
        return stats.isIndexing
            && request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func updateScanSnapshotPublishingPreference(for request: SearchRequest? = nil) {
        let query = request?.query ?? currentSearchText()
        let hasSearchInput = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        index.setPublishesSearchableSnapshotsDuringScan(hasSearchInput)
    }

    private func shouldBudgetSearchDuringIndexing(request: SearchRequest, stats: IndexStats? = nil) -> Bool {
        Self.shouldBudgetSearchDuringIndexing(request: request, stats: stats ?? indexStats)
    }

    nonisolated private static func shouldBudgetSearchDuringIndexing(request: SearchRequest, stats: IndexStats) -> Bool {
        let trimmedQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedQuery.isEmpty
            && stats.isIndexing
            && stats.optimizedCount < stats.searchableCount
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

        if index.hasResumableCheckpoint(for: indexedRoots) {
            startInitialRebuildIfNeeded()
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
        updateScanSnapshotPublishingPreference()
        index.replaceRootsAndRebuild(indexedRoots, mode: .resumeIfAvailable)
    }

    private func updateLoadingOverlay() {
        guard AppSettings.indexedRootsConfigured(defaults: defaults), !indexedRoots.isEmpty else {
            loadingOverlaySawActiveLoad = false
            loadingOverlay.isHidden = true
            updateMascotPlacementVisibility()
            return
        }

        let wasShowingLoadingOverlay = !loadingOverlay.isHidden
        let waitingForInitialLoad = !didRequestInitialSnapshotLoad && indexStats.indexedCount == 0
        let shouldShow = indexStats.isLoadingSnapshot || waitingForInitialLoad
        let canFlyDownAfterHiding = loadingOverlaySawActiveLoad

        if shouldShow, indexStats.isLoadingSnapshot {
            loadingOverlaySawActiveLoad = true
        }

        if indexStats.isLoadingSnapshot || waitingForInitialLoad {
            loadingLabel.stringValue = "Loading file list..."
        } else {
            loadingLabel.stringValue = indexStats.status
        }

        if wasShowingLoadingOverlay, !shouldShow, canFlyDownAfterHiding, beginLoadingMascotFlydownIfPossible() {
            loadingOverlaySawActiveLoad = false
            loadingOverlay.isHidden = true
            updateMascotPlacementVisibility()
            return
        }

        if !shouldShow {
            loadingOverlaySawActiveLoad = false
        }
        loadingOverlay.isHidden = !shouldShow
        updateMascotPlacementVisibility()
    }

    @discardableResult
    private func beginLoadingMascotFlydownIfPossible() -> Bool {
        guard
            !isMascotFlightInProgress,
            !isSetupMascotTuckInProgress,
            indexingSetupOverlay.isHidden,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            return false
        }

        view.layoutSubtreeIfNeeded()
        guard let currentImage = loadingMascotImageView.image else {
            return false
        }

        let startFrame = loadingMascotImageView.convert(loadingMascotImageView.bounds, to: view)
        let targetFrame = mascotPlacementTargetFrame()
        guard !startFrame.isEmpty, !targetFrame.isEmpty else {
            return false
        }

        loadingMascotImageView.isHidden = true
        return beginMascotFlight(
            image: currentImage,
            startFrame: startFrame,
            targetFrame: targetFrame,
            duration: 0.64,
            playback: .standalone(.flydown)
        ) {
            self.updateMascotPlacementVisibility()
        }
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
        guard !isMascotFlightInProgress else { return }

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

    private func mascotPlacementTargetFrame() -> NSRect {
        view.layoutSubtreeIfNeeded()

        if isExpandedMascotVisible {
            return expandedMascotImageView.convert(expandedMascotImageView.bounds, to: view)
        }

        return mascotImageView.convert(mascotImageView.bounds, to: view)
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
        let setupMascotVisible = !indexingSetupOverlay.isHidden
        let mascotFlightVisible = !mascotFlightImageView.isHidden
        let transientMascotOwnsPlacement = setupMascotVisible || mascotFlightVisible
        let loadingMascotVisible = !loadingOverlay.isHidden && !transientMascotOwnsPlacement

        loadingMascotImageView.isHidden = !loadingMascotVisible
        expandedMascotView.isHidden = transientMascotOwnsPlacement || loadingMascotVisible || !isExpandedMascotVisible
        mascotImageView.isHidden = transientMascotOwnsPlacement || loadingMascotVisible || isExpandedMascotVisible
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

    private func markSearchInputStarted() {
        if let event = NSApp.currentEvent {
            let eventAge = ProcessInfo.processInfo.systemUptime - event.timestamp
            pendingSearchInputStartedAt = Date(timeIntervalSinceNow: -max(eventAge, 0))
        } else {
            pendingSearchInputStartedAt = Date()
        }
    }

    private func settingsDidChange() {
        let updatedHighlightsSearchText = defaults.bool(forKey: AppSettings.highlightSearchTextKey)
        let updatedShowsHiddenFiles = defaults.bool(forKey: AppSettings.showHiddenFilesKey)
        let updatedAppFontFamilyName = AppSettings.appFontFamilyName(defaults: defaults)
        let updatedAppFontSize = AppSettings.appFontSize(defaults: defaults)

        if updatedHighlightsSearchText != highlightsSearchText {
            highlightsSearchText = updatedHighlightsSearchText
            tableView.reloadData()
        }

        if updatedAppFontFamilyName != appFontFamilyName || updatedAppFontSize != appFontSize {
            appFontFamilyName = updatedAppFontFamilyName
            appFontSize = updatedAppFontSize
            applyFontSettings()
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

    @objc private func appFontDidChange(_ notification: Notification) {
        settingsDidChange()
    }

    @objc private func matchColorsDidChange(_ notification: Notification) {
        tableView.reloadData()
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
        initialQueryElapsed = nil
        isRefiningSearchResults = false
        hasFinalSearchTiming = false
        activeSearchStartedAt = nil
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
        cancelFSEventCatchUp()
        fseventCursorStore.invalidate(roots: rootPaths(indexedRoots))
        updateScanSnapshotPublishingPreference()
        index.replaceRootsAndRebuild(indexedRoots, mode: .fresh)
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

    private func markFSEventBaselineIfNeeded(previous: IndexStats, current: IndexStats) {
        guard previous.isIndexing, !current.isIndexing, current.phase == .ready else { return }
        let completedFreshIndex = current.status.hasPrefix("Indexed") && !previous.resumedFromCheckpoint
        let completedFullReconcile = current.status.hasPrefix("Refreshed")
        guard completedFreshIndex || completedFullReconcile else { return }

        let rootPaths = rootPaths(index.allRoots())
        guard !rootPaths.isEmpty else { return }
        fseventCursorStore.markBaseline(for: rootPaths)
    }

    private func startWatchingIfNeeded() {
        guard AppSettings.indexedRootsConfigured(defaults: defaults), !indexedRoots.isEmpty else {
            cancelFSEventCatchUp()
            watcher.stop()
            return
        }

        watcher.start(roots: indexedRoots) { @MainActor @Sendable [weak self] events in
            self?.coalesceFSEvents(events)
        }
    }

    private func runFSEventsBackedReconciliation(roots: [URL]) {
        let roots = roots.map(\.standardizedFileURL)
        guard
            !roots.isEmpty,
            AppSettings.indexedRootsConfigured(defaults: defaults),
            rootPaths(roots) == rootPaths(indexedRoots),
            index.allExclusionPatterns() == AppSettings.exclusionPatterns(defaults: defaults)
        else {
            return
        }

        activeFSEventReplay?.cancel()
        let reconciliationID = UUID()
        activeFSEventReconciliationID = reconciliationID
        fseventCatchUpStartedAt = Date()
        updateStatus()

        activeFSEventReplay = fseventReconciler.reconcile(roots: roots) { @MainActor @Sendable [weak self] action in
            guard let self, self.activeFSEventReconciliationID == reconciliationID else { return }
            self.activeFSEventReplay = nil
            self.activeFSEventReconciliationID = nil
            self.fseventCatchUpStartedAt = nil

            switch action {
            case let .refresh(paths, cursorUpdates):
                guard !paths.isEmpty else {
                    self.fseventCursorStore.markBaseline(for: self.rootPaths(roots))
                    self.updateStatus()
                    return
                }
                self.index.refresh(paths: paths)
                self.fseventCursorStore.update(cursorUpdates)
            case let .upToDate(baselineEventID):
                self.fseventCursorStore.markBaseline(for: self.rootPaths(roots), eventID: baselineEventID)
                self.updateStatus()
            case let .fullReconcile(rootPaths):
                self.index.recordRecursiveRescan()
                let rootURLs = rootPaths?.map { URL(fileURLWithPath: $0, isDirectory: true) }
                self.index.reconcileIndexedRootsInBackground(rootURLs: rootURLs)
            }
        }
    }

    private func cancelFSEventCatchUp() {
        activeFSEventReplay?.cancel()
        activeFSEventReplay = nil
        activeFSEventReconciliationID = nil
        fseventCatchUpStartedAt = nil
    }

    private func coalesceFSEvents(_ events: [FileSystemEvent]) {
        pendingEventPaths.formUnion(events.map(\.path))
        pendingRecursiveEventPaths.formUnion(events.filter(\.requiresRecursiveRescan).map(\.path))
        eventDebounce?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let paths = Array(self.pendingEventPaths)
            let recursivePaths = Array(self.pendingRecursiveEventPaths)
            self.pendingEventPaths.removeAll(keepingCapacity: false)
            self.pendingRecursiveEventPaths.removeAll(keepingCapacity: false)
            guard !paths.isEmpty else { return }
            self.playMascotTransient(.fileChanged)
            if recursivePaths.isEmpty {
                self.index.refresh(paths: paths)
            } else {
                self.cancelFSEventCatchUp()
                self.index.recordRecursiveRescan()
                self.updateScanSnapshotPublishingPreference()
                self.index.replaceRootsAndRebuild(self.indexedRoots, mode: .fresh)
            }
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
        let usage = ProcessMemorySampler.currentUsage()
        memoryStatusText = ProcessMemoryFormatter.label(for: usage)
        if let usage {
            index.recordMemorySample(bytes: usage.displayBytes)
        }
    }

    private func updateStatus(refreshesMemory: Bool = false) {
        if refreshesMemory {
            refreshMemoryStatus()
        }

        guard AppSettings.indexedRootsConfigured(defaults: defaults) else {
            countLabel.stringValue = "0 shown / 0 matches • 0 indexed"
            statusLabel.stringValue = "Setup needed • Choose what AllTheThings can search • \(memoryStatusText)"
            return
        }

        let shownCount = results.count
        let indexed = indexStats.indexedCount.formatted()
        let total = totalMatches.formatted()
        var countSegments = [
            "\(shownCount.formatted()) shown / \(total) matches",
            "\(indexed) indexed"
        ]
        if !currentSearchText().isEmpty {
            countSegments.append(searchElapsedText())
        }
        countLabel.stringValue = countSegments.joined(separator: " • ")

        statusLabel.stringValue = "\(indexStatusText()) • \(memoryStatusText)"
    }

    private func searchElapsedText() -> String {
        let finalMilliseconds = Int((queryElapsed * 1_000).rounded())
        guard let initialQueryElapsed else {
            return "\(finalMilliseconds) ms"
        }

        let initialMilliseconds = Int((initialQueryElapsed * 1_000).rounded())
        if isRefiningSearchResults {
            return "\(initialMilliseconds) ms (refining)"
        }

        guard hasFinalSearchTiming else {
            return "\(initialMilliseconds) ms"
        }

        return "\(initialMilliseconds) ms (\(finalMilliseconds) ms)"
    }

    private func indexStatusText() -> String {
        if indexedRoots.isEmpty {
            return "No folders"
        }

        if let fseventCatchUpStartedAt {
            let elapsed = max(Date().timeIntervalSince(fseventCatchUpStartedAt), 0)
            return AppRuntimeStatusFormatter.catchUpStatus(elapsed: elapsed)
        }

        switch indexStats.phase {
        case .idle:
            return indexStats.status
        case .loading:
            return "Loading • \(indexStats.status)"
        case .scanning:
            if indexStats.status == "Refreshing changed paths" {
                return "\(indexStats.status) • \(indexStats.searchableCount.formatted()) searchable\(operationElapsedSuffix())"
            }
            let verb = indexStats.status.hasPrefix("Refreshing") ? "Refreshing" : "Indexing"
            return "\(verb) \(indexStats.discoveredCount.formatted()) discovered • \(indexStats.searchableCount.formatted()) searchable\(operationElapsedSuffix())"
        case .optimizing:
            return "\(indexStats.status) • \(indexStats.searchableCount.formatted()) searchable\(operationElapsedSuffix())"
        case .saving:
            return "Saving index • \(indexStats.searchableCount.formatted()) searchable\(operationElapsedSuffix())"
        case .ready:
            return "Ready • \(indexStats.status)"
        case .failed:
            return indexStats.status
        }
    }

    private func operationElapsedSuffix() -> String {
        guard let startedAt = indexStats.activeOperationStartedAt else { return "" }
        let elapsed = max(Date().timeIntervalSince(startedAt), 0)
        return " • \(AppRuntimeStatusFormatter.operationElapsed(elapsed))"
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

    private func highlightedPath(_ directoryPath: String, explanation: MatchExplanation?) -> NSAttributedString {
        let displayPath = AppSettings.displayPath(directoryPath)
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: AppSettings.appFont(defaults: defaults)
        ]
        return highlightedText(
            displayPath,
            field: .path,
            explanation: explanation,
            baseAttributes: attributes,
            originalPath: directoryPath
        )
    }

    private func highlightedText(
        _ text: String,
        field: MatchField,
        explanation: MatchExplanation?,
        baseAttributes: [NSAttributedString.Key: Any],
        originalPath: String? = nil
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text, attributes: baseAttributes)
        guard highlightsSearchText, let explanation else {
            return attributed
        }

        for span in explanation.spans where span.field == field || (field == .path && span.field == .ancestorPath) {
            guard let range = displayRange(for: span, in: text, originalPath: originalPath) else {
                continue
            }
            attributed.addAttributes(highlightAttributes(for: span.style), range: range)
        }

        return attributed
    }

    private func displayRange(for span: MatchSpan, in displayText: String, originalPath: String?) -> NSRange? {
        var location = span.location
        if
            let originalPath,
            displayText.hasPrefix("~"),
            originalPath.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path)
        {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let homeUTF16Count = home.utf16.count
            if location >= homeUTF16Count {
                location = 1 + (location - homeUTF16Count)
            }
        }

        guard location >= 0, span.length > 0, location + span.length <= displayText.utf16.count else {
            return nil
        }
        return NSRange(location: location, length: span.length)
    }

    private func highlightAttributes(for style: MatchSpanStyle) -> [NSAttributedString.Key: Any] {
        let color = highlightTextColor()
        switch style {
        case .contiguous:
            return [
                .foregroundColor: color,
                .font: AppSettings.appFont(defaults: defaults, weight: .bold)
            ]
        case .subsequence:
            return [
                .foregroundColor: color,
                .font: AppSettings.appFont(defaults: defaults, weight: .bold),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        case .typo:
            return [
                .foregroundColor: color,
                .font: AppSettings.appFont(defaults: defaults, weight: .bold),
                .backgroundColor: color.withAlphaComponent(0.18)
            ]
        }
    }

    private func highlightTextColor() -> NSColor {
        AppTheme.isDarkAppearance(for: view) ? .systemYellow : .systemOrange
    }

    private func matchLabel(for matchClass: MatchClass) -> String {
        switch matchClass {
        case .exact: "Exact"
        case .prefix: "Prefix"
        case .substring: "Text"
        case .near: "Near"
        case .weakPath: "Path"
        case .metadata: "Meta"
        }
    }

    private func matchIcon(for matchClass: MatchClass, accessibilityDescription: String) -> NSImage? {
        let candidates: [String] = switch matchClass {
        case .exact:
            ["checkmark.circle.fill", "checkmark.circle"]
        case .prefix:
            ["arrow.right.circle.fill", "arrow.right.circle"]
        case .substring:
            ["magnifyingglass.circle.fill", "magnifyingglass.circle", "magnifyingglass"]
        case .near:
            ["sparkles", "wand.and.stars", "waveform.path.ecg"]
        case .weakPath:
            ["folder.fill", "folder"]
        case .metadata:
            ["tag.fill", "tag"]
        }

        for symbolName in candidates {
            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription) {
                image.isTemplate = true
                return image
            }
        }
        return nil
    }

    private func matchColor(for quality: MatchQuality) -> NSColor {
        AppSettings.matchColor(
            for: quality.matchClass,
            isDark: AppTheme.isDarkAppearance(for: view),
            defaults: defaults
        )
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
        beginSetupMascotTuckAwayIfPossible()
        indexedRoots.append(contentsOf: additions)
        saveRoots()
        didRequestInitialSnapshotLoad = true
        didRequestInitialRebuild = true
        startWatchingIfNeeded()
        cancelFSEventCatchUp()
        fseventCursorStore.invalidate(roots: rootPaths(indexedRoots))
        updateScanSnapshotPublishingPreference()
        index.replaceRootsAndRebuild(indexedRoots, mode: .fresh)
        updateSetupSuggestions()
    }

    @objc private func reindex(_ sender: Any?) {
        guard AppSettings.indexedRootsConfigured(defaults: defaults), !indexedRoots.isEmpty else { return }
        didRequestInitialSnapshotLoad = true
        didRequestInitialRebuild = true
        cancelFSEventCatchUp()
        fseventCursorStore.invalidate(roots: rootPaths(indexedRoots))
        updateScanSnapshotPublishingPreference()
        index.replaceRootsAndRebuild(indexedRoots, mode: .fresh)
    }

    @objc private func searchFieldDidChange(_ sender: NSSearchField) {
        markSearchInputStarted()
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
        index.recordFileAction(.open)
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

        index.recordFileAction(.open)
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
        index.recordFileAction(.reveal)
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
            index.recordFileAction(.moveToTrash)
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
        } else {
            index.recordFileAction(.getInfo)
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
            index.recordFileAction(.rename)
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
            index.recordFileAction(.quickLook)
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
        index.recordFileAction(.copyFile)
    }

    @objc private func copySelectedPath(_ sender: Any?) {
        let records = selectedRecords()
        guard !records.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(records.map(\.path).joined(separator: "\n"), forType: .string)
        index.recordFileAction(.copyPath)
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
        defaults.set(2, forKey: DefaultsKey.visibleColumnsSchema)
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
        if defaults.integer(forKey: DefaultsKey.visibleColumnsSchema) < 2 {
            columns.insert(.match)
        }
        return columns
    }

    private static func normalizedSortSpec(_ spec: SortSpec, visibleColumns: Set<Column>) -> SortSpec {
        guard let column = Column.column(for: spec.column), visibleColumns.contains(column) else {
            return defaultSortSpec
        }

        return spec
    }
}
