import AppKit
import ATTCore

final class SearchWindowController: NSWindowController {
    init(index: FileIndex) {
        let viewController = SearchViewController(index: index)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "AllTheThings"
        window.titlebarAppearsTransparent = true
        window.contentViewController = viewController
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
            case .name: 260
            case .path: 420
            case .modified: 150
            case .size: 96
            case .created: 150
            case .ext: 70
            case .kind: 80
            case .volume: 120
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
    }

    private let index: FileIndex
    private let watcher = FileSystemWatcher()
    private let searchQueue = DispatchQueue(label: "att.search", qos: .userInitiated)
    private let defaults = UserDefaults.standard
    private let rootsKey = "ATTIndexedRoots"

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton()
    private let revealButton = NSButton()
    private let copyButton = NSButton()
    private let addScopeButton = NSButton()
    private let reindexButton = NSButton()

    private var results: [SearchResult] = []
    private var indexStats: IndexStats
    private var totalMatches = 0
    private var queryElapsed: TimeInterval = 0
    private var queryGeneration: UInt64 = 0
    private var sortSpec = SortSpec(column: .modified, ascending: false)
    private var indexedRoots: [URL]
    private var pendingEventPaths = Set<String>()
    private var eventDebounce: DispatchWorkItem?

    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private lazy var byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    init(index: FileIndex) {
        self.index = index
        self.indexStats = index.currentStats()
        self.indexedRoots = Self.loadRoots(defaults: defaults, key: rootsKey)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        buildInterface()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        index.onStatsChanged = { [weak self] stats in
            DispatchQueue.main.async {
                self?.indexStats = stats
                self?.updateStatus()
                self?.scheduleSearch()
            }
        }

        startWatching()

        if indexStats.indexedCount == 0 {
            index.replaceRootsAndRebuild(indexedRoots)
        } else {
            scheduleSearch()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
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
            textField?.stringValue = record.directoryPath
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

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first else { return }
        sortSpec = sortSpec(for: descriptor)
        scheduleSearch()
    }

    func controlTextDidChange(_ obj: Notification) {
        scheduleSearch()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Open", action: #selector(openSelected(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealSelected(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy Path", action: #selector(copySelectedPath(_:)), keyEquivalent: "")
    }

    private func buildInterface() {
        let topBar = NSStackView()
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.spacing = 8
        topBar.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 8, right: 14)
        topBar.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search filenames and paths"
        searchField.delegate = self
        searchField.controlSize = .large
        searchField.font = .systemFont(ofSize: 16)
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

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = tableView

        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowSizeStyle = .medium
        tableView.style = .fullWidth
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.doubleAction = #selector(openSelected(_:))
        tableView.target = self

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = min(column.width, 70)
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column != .modified && column != .size)
            tableView.addTableColumn(tableColumn)
        }
        tableView.sortDescriptors = [NSSortDescriptor(key: Column.modified.rawValue, ascending: false)]

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

        footer.addArrangedSubview(countLabel)
        footer.addArrangedSubview(statusLabel)

        view.addSubview(topBar)
        view.addSubview(scrollView)
        view.addSubview(footer)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),

            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])

        updateActionButtons()
        updateStatus()
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
        textField.font = .systemFont(ofSize: 13)
        cell.addSubview(textField)
        cell.textField = textField

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])

        return cell
    }

    private func scheduleSearch() {
        queryGeneration &+= 1
        let generation = queryGeneration
        let request = SearchRequest(query: searchField.stringValue, sort: sortSpec)
        let index = self.index

        searchQueue.async {
            let response = index.search(request)

            DispatchQueue.main.async { [weak self] in
                guard let self, self.queryGeneration == generation else { return }
                self.results = response.results
                self.totalMatches = response.totalMatches
                self.queryElapsed = response.elapsed
                self.tableView.reloadData()
                self.updateStatus()
                self.updateActionButtons()
            }
        }
    }

    private func startWatching() {
        watcher.start(roots: indexedRoots) { [weak self] paths in
            DispatchQueue.main.async {
                self?.coalesceFSEvents(paths)
            }
        }
    }

    private func coalesceFSEvents(_ paths: [String]) {
        pendingEventPaths.formUnion(paths)
        eventDebounce?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let paths = Array(self.pendingEventPaths)
            self.pendingEventPaths.removeAll(keepingCapacity: true)
            self.index.refresh(paths: paths)
        }

        eventDebounce = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func updateStatus() {
        let shownCount = results.count
        let indexed = indexStats.indexedCount.formatted()
        let total = totalMatches.formatted()
        let milliseconds = Int((queryElapsed * 1_000).rounded())
        countLabel.stringValue = "\(shownCount.formatted()) shown / \(total) matches • \(indexed) indexed • \(milliseconds) ms"

        let scopeText = indexedRoots.map(\.path).joined(separator: "  ")
        let indexingText = indexStats.isIndexing ? "Indexing" : "Ready"
        statusLabel.stringValue = "\(indexingText) • \(indexStats.status) • \(scopeText)"
    }

    private func updateActionButtons() {
        let enabled = selectedRecord() != nil
        openButton.isEnabled = enabled
        revealButton.isEnabled = enabled
        copyButton.isEnabled = enabled
    }

    private func selectedRecord() -> FileRecord? {
        let row = tableView.selectedRow
        guard row >= 0, row < results.count else { return nil }
        return results[row].record
    }

    private func highlightedName(_ name: String) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: name, attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
        ])

        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = FuzzyMatcher.primaryHighlightToken(for: query) else {
            return attributed
        }

        let normalizedName = FuzzyMatcher.normalize(name)
        if let range = normalizedName.range(of: token) {
            let lower = normalizedName.distance(from: normalizedName.startIndex, to: range.lowerBound)
            let upper = normalizedName.distance(from: normalizedName.startIndex, to: range.upperBound)
            attributed.addAttributes([
                .foregroundColor: NSColor.systemYellow,
                .font: NSFont.systemFont(ofSize: 13, weight: .bold)
            ], range: NSRange(location: lower, length: upper - lower))
        }

        return attributed
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

    @objc private func addScope(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Index"

        guard panel.runModal() == .OK else { return }

        let existing = Set(indexedRoots.map { $0.standardizedFileURL.path })
        let additions = panel.urls
            .map(\.standardizedFileURL)
            .filter { !existing.contains($0.path) }

        guard !additions.isEmpty else { return }
        indexedRoots.append(contentsOf: additions)
        saveRoots()
        startWatching()
        index.replaceRootsAndRebuild(indexedRoots)
    }

    @objc private func reindex(_ sender: Any?) {
        index.replaceRootsAndRebuild(indexedRoots)
    }

    @objc private func openSelected(_ sender: Any?) {
        guard let record = selectedRecord() else { return }
        NSWorkspace.shared.open(record.url)
    }

    @objc private func revealSelected(_ sender: Any?) {
        guard let record = selectedRecord() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([record.url])
    }

    @objc private func copySelectedPath(_ sender: Any?) {
        guard let record = selectedRecord() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.path, forType: .string)
    }

    private func saveRoots() {
        defaults.set(indexedRoots.map(\.path), forKey: rootsKey)
    }

    private static func loadRoots(defaults: UserDefaults, key: String) -> [URL] {
        if let saved = defaults.array(forKey: key) as? [String], !saved.isEmpty {
            return saved.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }

        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Developer", isDirectory: true),
            URL(fileURLWithPath: "/Applications", isDirectory: true)
        ]

        let roots = candidates.filter { fileManager.fileExists(atPath: $0.path) }
        defaults.set(roots.map(\.path), forKey: key)
        return roots
    }
}
