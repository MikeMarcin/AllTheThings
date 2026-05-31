import AppKit
import ATTCore

@MainActor
final class InsightsWindowController: NSWindowController {
    init(
        index: FileIndex,
        defaults: UserDefaults = .standard,
        clearCachedIndexHandler: @escaping () throws -> Void
    ) {
        let contentSize = NSSize(width: 980, height: 760)
        let viewController = InsightsViewController(
            index: index,
            defaults: defaults,
            clearCachedIndexHandler: clearCachedIndexHandler
        )
        viewController.preferredContentSize = contentSize

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Insights"
        window.isRestorable = false
        window.contentMinSize = NSSize(width: 860, height: 640)
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

@MainActor
private final class InsightsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let index: FileIndex
    private let defaults: UserDefaults
    private let clearCachedIndexHandler: () throws -> Void

    private let scrollView = NSScrollView()
    private let contentView = FlippedView()
    private let overviewGrid = NSGridView()
    private let treemapView = InsightsTreemapView()
    private let activityChartView = InsightsBarChartView()
    private let rootsTableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "Loading insights...")
    private let revealDataFolderButton = NSButton()
    private let clearCachedIndexButton = NSButton()
    private let copyReportButton = NSButton()
    private let saveReportButton = NSButton()
    private let storageSummaryLabel = NSTextField(labelWithString: "")
    private let performanceSummaryLabel = NSTextField(labelWithString: "")
    private let healthSummaryLabel = NSTextField(labelWithString: "")
    private let lifetimeSummaryLabel = NSTextField(labelWithString: "")

    private var refreshTimer: Timer?
    private var latestSnapshot: IndexInsightsSnapshot?
    private var displayedRoots: [IndexRootInsight] = []
    private var isRefreshingInsights = false

    init(
        index: FileIndex,
        defaults: UserDefaults,
        clearCachedIndexHandler: @escaping () throws -> Void
    ) {
        self.index = index
        self.defaults = defaults
        self.clearCachedIndexHandler = clearCachedIndexHandler
        AppSettings.registerDefaults(defaults)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = ThemedBackgroundView(frame: NSRect(x: 0, y: 0, width: 980, height: 760))
        buildInterface()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refreshInsights()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        startPolling()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopPolling()
    }

    private func buildInterface() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentView

        let titleLabel = NSTextField(labelWithString: "Insights")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        titleLabel.textColor = .labelColor

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 13, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor

        configureTextButton(revealDataFolderButton, title: "Reveal Data Folder", symbol: "folder", action: #selector(revealDataFolder(_:)))
        configureTextButton(clearCachedIndexButton, title: "Clear Cached Index...", symbol: "trash", action: #selector(clearCachedIndex(_:)))
        configureTextButton(copyReportButton, title: "Copy Diagnostics Report", symbol: "doc.on.doc", action: #selector(copyDiagnosticsReport(_:)))
        configureTextButton(saveReportButton, title: "Save Diagnostics Report...", symbol: "square.and.arrow.down", action: #selector(saveDiagnosticsReport(_:)))

        let buttonStack = NSStackView(views: [
            revealDataFolderButton,
            clearCachedIndexButton,
            copyReportButton,
            saveReportButton
        ])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8

        overviewGrid.translatesAutoresizingMaskIntoConstraints = false
        overviewGrid.rowSpacing = 10
        overviewGrid.columnSpacing = 10
        overviewGrid.xPlacement = .fill
        overviewGrid.yPlacement = .fill

        let overviewCard = makeCard(containing: overviewGrid)

        let storageLabel = makeSectionLabel("Storage")
        treemapView.translatesAutoresizingMaskIntoConstraints = false
        storageSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        storageSummaryLabel.font = .systemFont(ofSize: 12)
        storageSummaryLabel.textColor = .secondaryLabelColor
        storageSummaryLabel.lineBreakMode = .byWordWrapping
        storageSummaryLabel.maximumNumberOfLines = 3
        let storageStack = verticalStack([treemapView, storageSummaryLabel], spacing: 10)
        let storageCard = makeCard(containing: storageStack)

        let rootsLabel = makeSectionLabel("Indexed Roots")
        configureRootsTable()
        let rootsScrollView = NSScrollView()
        rootsScrollView.translatesAutoresizingMaskIntoConstraints = false
        rootsScrollView.hasVerticalScroller = true
        rootsScrollView.hasHorizontalScroller = false
        rootsScrollView.borderType = .noBorder
        rootsScrollView.documentView = rootsTableView
        let rootsCard = makeCard(containing: rootsScrollView)

        let activityLabel = makeSectionLabel("Activity")
        activityChartView.translatesAutoresizingMaskIntoConstraints = false
        performanceSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        performanceSummaryLabel.font = .systemFont(ofSize: 12)
        performanceSummaryLabel.textColor = .secondaryLabelColor
        performanceSummaryLabel.lineBreakMode = .byWordWrapping
        performanceSummaryLabel.maximumNumberOfLines = 4
        let activityCard = makeCard(containing: verticalStack([activityChartView, performanceSummaryLabel], spacing: 10))

        let healthLabel = makeSectionLabel("Performance & Health")
        healthSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        healthSummaryLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        healthSummaryLabel.textColor = .secondaryLabelColor
        healthSummaryLabel.lineBreakMode = .byWordWrapping
        healthSummaryLabel.maximumNumberOfLines = 12
        let healthCard = makeCard(containing: healthSummaryLabel)

        let lifetimeLabel = makeSectionLabel("Lifetime")
        lifetimeSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        lifetimeSummaryLabel.font = .systemFont(ofSize: 12)
        lifetimeSummaryLabel.textColor = .secondaryLabelColor
        lifetimeSummaryLabel.lineBreakMode = .byWordWrapping
        lifetimeSummaryLabel.maximumNumberOfLines = 4
        let lifetimeCard = makeCard(containing: lifetimeSummaryLabel)

        for item in [
            titleLabel,
            statusLabel,
            buttonStack,
            overviewCard,
            storageLabel,
            storageCard,
            rootsLabel,
            rootsCard,
            activityLabel,
            activityCard,
            healthLabel,
            healthCard,
            lifetimeLabel,
            lifetimeCard
        ] {
            contentView.addSubview(item)
        }
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),

            titleLabel.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor, constant: 26),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),

            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -32),

            buttonStack.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),

            overviewCard.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 18),
            overviewCard.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            overviewCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),

            storageLabel.topAnchor.constraint(equalTo: overviewCard.bottomAnchor, constant: 26),
            storageLabel.leadingAnchor.constraint(equalTo: overviewCard.leadingAnchor),

            storageCard.topAnchor.constraint(equalTo: storageLabel.bottomAnchor, constant: 10),
            storageCard.leadingAnchor.constraint(equalTo: overviewCard.leadingAnchor),
            storageCard.widthAnchor.constraint(equalTo: overviewCard.widthAnchor, multiplier: 0.48),
            treemapView.heightAnchor.constraint(equalToConstant: 230),

            rootsLabel.topAnchor.constraint(equalTo: storageLabel.topAnchor),
            rootsLabel.leadingAnchor.constraint(equalTo: storageCard.trailingAnchor, constant: 18),

            rootsCard.topAnchor.constraint(equalTo: rootsLabel.bottomAnchor, constant: 10),
            rootsCard.leadingAnchor.constraint(equalTo: rootsLabel.leadingAnchor),
            rootsCard.trailingAnchor.constraint(equalTo: overviewCard.trailingAnchor),
            rootsCard.heightAnchor.constraint(equalTo: storageCard.heightAnchor),
            rootsScrollView.heightAnchor.constraint(equalToConstant: 270),

            activityLabel.topAnchor.constraint(equalTo: storageCard.bottomAnchor, constant: 26),
            activityLabel.leadingAnchor.constraint(equalTo: overviewCard.leadingAnchor),

            activityCard.topAnchor.constraint(equalTo: activityLabel.bottomAnchor, constant: 10),
            activityCard.leadingAnchor.constraint(equalTo: overviewCard.leadingAnchor),
            activityCard.widthAnchor.constraint(equalTo: storageCard.widthAnchor),
            activityChartView.heightAnchor.constraint(equalToConstant: 170),

            healthLabel.topAnchor.constraint(equalTo: activityLabel.topAnchor),
            healthLabel.leadingAnchor.constraint(equalTo: activityCard.trailingAnchor, constant: 18),

            healthCard.topAnchor.constraint(equalTo: healthLabel.bottomAnchor, constant: 10),
            healthCard.leadingAnchor.constraint(equalTo: healthLabel.leadingAnchor),
            healthCard.trailingAnchor.constraint(equalTo: overviewCard.trailingAnchor),
            healthCard.heightAnchor.constraint(equalTo: activityCard.heightAnchor),

            lifetimeLabel.topAnchor.constraint(equalTo: activityCard.bottomAnchor, constant: 26),
            lifetimeLabel.leadingAnchor.constraint(equalTo: overviewCard.leadingAnchor),

            lifetimeCard.topAnchor.constraint(equalTo: lifetimeLabel.bottomAnchor, constant: 10),
            lifetimeCard.leadingAnchor.constraint(equalTo: overviewCard.leadingAnchor),
            lifetimeCard.trailingAnchor.constraint(equalTo: overviewCard.trailingAnchor),
            lifetimeCard.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -28)
        ])
    }

    private func startPolling() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshInsights()
            }
        }
    }

    private func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refreshInsights() {
        guard !isRefreshingInsights else { return }
        isRefreshingInsights = true
        let index = self.index
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = index.currentInsightsSnapshot()
            DispatchQueue.main.async {
                self?.isRefreshingInsights = false
                self?.apply(snapshot: snapshot)
            }
        }
    }

    private func apply(snapshot: IndexInsightsSnapshot) {
        latestSnapshot = snapshot
        displayedRoots = snapshot.roots
        sortDisplayedRoots()

        statusLabel.stringValue = "\(snapshot.stats.status) - updated \(relativeDateString(snapshot.stats.lastUpdated))"
        clearCachedIndexButton.isEnabled = snapshot.health.canClearCachedIndex

        rebuildOverviewGrid(snapshot)
        treemapView.roots = displayedRoots
        activityChartView.buckets = Array(snapshot.usage.dailyBuckets.suffix(30))
        rootsTableView.reloadData()

        storageSummaryLabel.stringValue = "ATT data uses \(byteString(snapshot.storage.totalATTDataBytes)). The index package is \(byteString(snapshot.storage.indexPackageBytes)); root attribution is estimated from indexed path weight."
        performanceSummaryLabel.stringValue = "Searches: \(snapshot.usage.allTimeSearches.completed.formatted()) completed, \(snapshot.usage.allTimeSearches.fallbackScans.formatted()) full fallback scans, average latency \(durationString(snapshot.usage.allTimeSearches.averageLatency))."
        healthSummaryLabel.stringValue = healthText(snapshot)
        lifetimeSummaryLabel.stringValue = lifetimeText(snapshot)
    }

    private func rebuildOverviewGrid(_ snapshot: IndexInsightsSnapshot) {
        while overviewGrid.numberOfRows > 0 {
            overviewGrid.removeRow(at: 0)
        }

        let tiles = [
            makeMetricTile(title: "Tracked Files", value: snapshot.stats.indexedCount.formatted(), detail: "\(snapshot.roots.count) roots"),
            makeMetricTile(title: "ATT Data", value: byteString(snapshot.storage.totalATTDataBytes), detail: "Index \(byteString(snapshot.storage.indexPackageBytes))"),
            makeMetricTile(title: "Searches", value: snapshot.usage.allTimeSearches.completed.formatted(), detail: "\(snapshot.usage.allTimeSearches.fallbackScans.formatted()) fallbacks"),
            makeMetricTile(title: "Index Updates", value: snapshot.usage.health.incrementalRefreshBatches.formatted(), detail: "\(snapshot.usage.health.fullRebuilds.formatted()) rebuilds"),
            makeMetricTile(title: "Memory", value: byteString(snapshot.usage.dailyBuckets.last?.memory.latestBytes ?? 0), detail: "latest sample"),
            makeMetricTile(title: "Launches", value: snapshot.lifetime.launchCount.formatted(), detail: dateOnlyString(snapshot.lifetime.firstLaunchDate))
        ]

        for rowStart in stride(from: 0, to: tiles.count, by: 3) {
            let rowViews = Array(tiles[rowStart..<min(rowStart + 3, tiles.count)])
            overviewGrid.addRow(with: rowViews)
        }
    }

    private func configureRootsTable() {
        rootsTableView.translatesAutoresizingMaskIntoConstraints = false
        rootsTableView.headerView = NSTableHeaderView()
        rootsTableView.rowHeight = 34
        rootsTableView.usesAlternatingRowBackgroundColors = false
        rootsTableView.dataSource = self
        rootsTableView.delegate = self

        for column in [
            makeTableColumn("root", title: "Root", width: 170),
            makeTableColumn("files", title: "Files", width: 72),
            makeTableColumn("content", title: "Content", width: 82),
            makeTableColumn("estimate", title: "Index Est.", width: 82)
        ] {
            rootsTableView.addTableColumn(column)
        }
    }

    private func makeTableColumn(_ identifier: String, title: String, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = 58
        column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: identifier != "estimate")
        return column
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        sortDisplayedRoots()
        tableView.reloadData()
    }

    private func sortDisplayedRoots() {
        guard let descriptor = rootsTableView.sortDescriptors.first else {
            displayedRoots.sort {
                if $0.estimatedIndexBytes != $1.estimatedIndexBytes {
                    return $0.estimatedIndexBytes > $1.estimatedIndexBytes
                }
                return $0.path < $1.path
            }
            return
        }

        let ascending = descriptor.ascending
        switch descriptor.key {
        case "root":
            displayedRoots.sort { ascending ? $0.path < $1.path : $0.path > $1.path }
        case "files":
            displayedRoots.sort { ascending ? $0.trackedFileCount < $1.trackedFileCount : $0.trackedFileCount > $1.trackedFileCount }
        case "content":
            displayedRoots.sort { ascending ? $0.indexedContentBytes < $1.indexedContentBytes : $0.indexedContentBytes > $1.indexedContentBytes }
        case "estimate":
            displayedRoots.sort { ascending ? $0.estimatedIndexBytes < $1.estimatedIndexBytes : $0.estimatedIndexBytes > $1.estimatedIndexBytes }
        default:
            break
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayedRoots.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < displayedRoots.count, let identifier = tableColumn?.identifier.rawValue else { return nil }
        let root = displayedRoots[row]
        let cell = NSTextField(labelWithString: "")
        cell.font = identifier == "root" ? .systemFont(ofSize: 12, weight: .medium) : .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        cell.textColor = identifier == "root" ? .labelColor : .secondaryLabelColor
        cell.lineBreakMode = .byTruncatingMiddle

        switch identifier {
        case "root":
            cell.stringValue = AppSettings.displayPath(root.path)
            cell.toolTip = root.path
        case "files":
            cell.stringValue = root.trackedFileCount.formatted()
        case "content":
            cell.stringValue = byteString(root.indexedContentBytes)
        case "estimate":
            cell.stringValue = byteString(root.estimatedIndexBytes)
        default:
            cell.stringValue = ""
        }

        return cell
    }

    @objc private func revealDataFolder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([index.dataDirectoryURL])
    }

    @objc private func clearCachedIndex(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear cached index?"
        alert.informativeText = "This deletes only the persisted ATT index package and temporary index packages. Settings, indexed folders, exclusions, event cursors, aggregate metrics, install date, and diagnostics counters are kept. The index will rebuild from current folders."
        alert.addButton(withTitle: "Clear Index")
        alert.addButton(withTitle: "Cancel")

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try self.clearCachedIndexHandler()
                self.refreshInsights()
            } catch {
                self.presentError("Could not clear cached index.", informativeText: error.localizedDescription)
            }
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    @objc private func copyDiagnosticsReport(_ sender: Any?) {
        let checkbox = NSButton(checkboxWithTitle: "Include indexed root paths", target: nil, action: nil)
        checkbox.state = .off

        let alert = NSAlert()
        alert.messageText = "Copy diagnostics report?"
        alert.informativeText = "The report is redacted by default and includes aggregate counters only."
        alert.accessoryView = checkbox
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Cancel")

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, let snapshot = self.latestSnapshot else { return }
            let report = DiagnosticsReportBuilder.build(
                snapshot: snapshot,
                defaults: self.defaults,
                includeRootPaths: checkbox.state == .on
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    @objc private func saveDiagnosticsReport(_ sender: Any?) {
        guard let snapshot = latestSnapshot else { return }

        let checkbox = NSButton(checkboxWithTitle: "Include indexed root paths", target: nil, action: nil)
        checkbox.state = .off

        let panel = NSSavePanel()
        panel.title = "Save Diagnostics Report"
        panel.nameFieldStringValue = "AllTheThings-Diagnostics.txt"
        panel.canCreateDirectories = true
        panel.accessoryView = checkbox

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            let report = DiagnosticsReportBuilder.build(
                snapshot: snapshot,
                defaults: self.defaults,
                includeRootPaths: checkbox.state == .on
            )
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self.presentError("Could not save diagnostics report.", informativeText: error.localizedDescription)
            }
        }

        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func presentError(_ message: String, informativeText: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = informativeText
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func healthText(_ snapshot: IndexInsightsSnapshot) -> String {
        let searches = snapshot.usage.allTimeSearches
        let health = snapshot.usage.health
        return [
            "fast paths: \(searches.indexedCandidateSearches.formatted())",
            "fallback scans: \(searches.fallbackScans.formatted())",
            "latency avg/max: \(durationString(searches.averageLatency)) / \(durationString(searches.maxLatency))",
            "candidate rows: \(searches.candidateRowsExamined.formatted())",
            "full-scan rows: \(searches.scannedRowsExamined.formatted())",
            "snapshot load failures: \(health.snapshotLoadFailures.formatted())",
            "persist failures: \(health.persistFailures.formatted())",
            "active jobs: \(snapshot.health.activeIndexJobs)",
            "schema: \(snapshot.health.schemaVersion)",
            "path index: \(snapshot.health.pathGramIndexEnabled ? "enabled" : "disabled")"
        ].joined(separator: "\n")
    }

    private func lifetimeText(_ snapshot: IndexInsightsSnapshot) -> String {
        let firstLaunch = dateOnlyString(snapshot.lifetime.firstLaunchDate)
        let versionSeen = dateOnlyString(snapshot.lifetime.currentAppVersionFirstSeenDate)
        let daily = snapshot.usage.dailyBuckets.last
        let memory = daily.map { "Today memory min/max: \(byteString($0.memory.dailyMinimumBytes)) / \(byteString($0.memory.dailyMaximumBytes))" } ?? "No memory samples yet"
        return "First launch: \(firstLaunch). Launches: \(snapshot.lifetime.launchCount.formatted()). Current version first seen: \(versionSeen). \(memory)."
    }

    private func configureTextButton(_ button: NSButton, title: String, symbol: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.toolTip = title
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func makeSectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeMetricTile(title: String, value: String, detail: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.maximumNumberOfLines = 1

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        let stack = verticalStack([titleLabel, valueLabel, detailLabel], spacing: 3)
        stack.wantsLayer = true
        stack.layer?.cornerRadius = 6
        stack.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        NSLayoutConstraint.activate([
            stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 86)
        ])
        return stack
    }

    private func makeCard(containing content: NSView) -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.45).cgColor

        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])
        return card
    }

    private func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = spacing
        return stack
    }

    private func byteString(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    private func durationString(_ duration: TimeInterval) -> String {
        if duration <= 0 {
            return "0 ms"
        }
        if duration < 1 {
            return "\(Int((duration * 1_000).rounded())) ms"
        }
        return String(format: "%.2f s", duration)
    }

    private func dateOnlyString(_ date: Date?) -> String {
        guard let date else { return "unknown" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func relativeDateString(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private final class InsightsTreemapView: NSView {
    var roots: [IndexRootInsight] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        guard !roots.isEmpty else {
            drawEmpty("No indexed roots")
            return
        }

        let total = roots.reduce(UInt64(0)) { $0 &+ max($1.estimatedIndexBytes, UInt64($1.trackedFileCount)) }
        guard total > 0 else {
            drawEmpty("No indexed data yet")
            return
        }

        var remaining = bounds.insetBy(dx: 1, dy: 1)
        let palette: [NSColor] = [.systemBlue, .systemGreen, .systemPink, .systemOrange, .systemPurple, .systemTeal]

        for (index, root) in roots.enumerated() {
            let weight = max(root.estimatedIndexBytes, UInt64(root.trackedFileCount))
            let fraction = CGFloat(Double(weight) / Double(total))
            let isLast = index == roots.count - 1
            let rect: NSRect
            if remaining.width >= remaining.height {
                let width = isLast ? remaining.width : max(1, floor(remaining.width * fraction))
                rect = NSRect(x: remaining.minX, y: remaining.minY, width: width, height: remaining.height)
                remaining.origin.x += width
                remaining.size.width -= width
            } else {
                let height = isLast ? remaining.height : max(1, floor(remaining.height * fraction))
                rect = NSRect(x: remaining.minX, y: remaining.minY, width: remaining.width, height: height)
                remaining.origin.y += height
                remaining.size.height -= height
            }

            let color = palette[index % palette.count]
            color.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5).fill()

            if rect.width > 84, rect.height > 42 {
                let label = "Root \(index + 1)\n\(root.trackedFileCount.formatted()) files"
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.white
                ]
                label.draw(
                    in: rect.insetBy(dx: 8, dy: 7),
                    withAttributes: attributes
                )
            }
        }
    }

    private func drawEmpty(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}

private final class InsightsBarChartView: NSView {
    var buckets: [DailyUsageBucket] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        guard !buckets.isEmpty else {
            drawEmpty("No activity yet")
            return
        }

        let values = buckets.map { max($0.searches.completed, $0.fileActions.values.reduce(UInt64(0), +), $0.health.incrementalRefreshBatches + $0.health.fullRebuilds) }
        let maxValue = max(values.max() ?? 0, 1)
        let plot = bounds.insetBy(dx: 8, dy: 10)
        let gap: CGFloat = 3
        let barWidth = max(3, (plot.width - CGFloat(max(buckets.count - 1, 0)) * gap) / CGFloat(max(buckets.count, 1)))

        for (index, bucket) in buckets.enumerated() {
            let x = plot.minX + CGFloat(index) * (barWidth + gap)
            let searchHeight = CGFloat(Double(bucket.searches.completed) / Double(maxValue)) * plot.height
            let actionCount = bucket.fileActions.values.reduce(UInt64(0), +)
            let actionHeight = CGFloat(Double(actionCount) / Double(maxValue)) * plot.height
            let updateHeight = CGFloat(Double(bucket.health.incrementalRefreshBatches + bucket.health.fullRebuilds) / Double(maxValue)) * plot.height

            drawBar(x: x, width: barWidth, height: searchHeight, color: .systemBlue, plot: plot)
            drawBar(x: x, width: barWidth, height: actionHeight, color: .systemGreen.withAlphaComponent(0.75), plot: plot.insetBy(dx: barWidth * 0.25, dy: 0))
            drawBar(x: x, width: barWidth, height: updateHeight, color: .systemOrange.withAlphaComponent(0.8), plot: plot.insetBy(dx: barWidth * 0.42, dy: 0))
        }

        let legend = "Blue searches  Green file actions  Orange index updates"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        legend.draw(at: NSPoint(x: plot.minX, y: bounds.maxY - 14), withAttributes: attributes)
    }

    private func drawBar(x: CGFloat, width: CGFloat, height: CGFloat, color: NSColor, plot: NSRect) {
        guard height > 0 else { return }
        color.setFill()
        let rect = NSRect(x: x, y: plot.maxY - height, width: width, height: height)
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
    }

    private func drawEmpty(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}
