import AppKit
import ATTCore
import Carbon.HIToolbox
import Darwin

@MainActor
final class InsightsWindowController: NSWindowController {
    static let defaultContentSize = NSSize(width: 900, height: 720)
    static let minimumContentSize = NSSize(width: 720, height: 560)
    private static let screenMargin: CGFloat = 18

    init(
        index: FileIndex,
        defaults: UserDefaults = .standard,
        clearCachedIndexHandler: @escaping () throws -> Void
    ) {
        let initialVisibleFrame = Self.targetVisibleFrame(for: nil)
        let contentSize = Self.clampedContentSize(
            Self.defaultContentSize,
            visibleFrame: initialVisibleFrame
        )
        let viewController = InsightsViewController(
            index: index,
            defaults: defaults,
            clearCachedIndexHandler: clearCachedIndexHandler
        )
        viewController.preferredContentSize = contentSize

        let window = InsightsWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Insights"
        window.isRestorable = false
        window.contentMinSize = Self.clampedContentSize(
            Self.minimumContentSize,
            visibleFrame: initialVisibleFrame
        )
        window.contentViewController = viewController
        window.setContentSize(contentSize)
        Self.placeWindowForOpening(window)

        super.init(window: window)
    }

    override func showWindow(_ sender: Any?) {
        if let window {
            Self.placeWindowForOpening(window)
        }
        super.showWindow(sender)
        if let window {
            Self.constrainWindowToVisibleScreen(window)
        }
    }

    static func clampedContentSize(_ size: NSSize, visibleFrame: NSRect?) -> NSSize {
        guard let visibleFrame else { return size }

        let maxWidth = max(1, visibleFrame.width - screenMargin * 2)
        let maxHeight = max(1, visibleFrame.height - screenMargin * 2)
        return NSSize(
            width: min(size.width, maxWidth),
            height: min(size.height, maxHeight)
        )
    }

    static func openingFrameFittingVisibleScreen(_ frame: NSRect, visibleFrame: NSRect) -> NSRect {
        let size = sizeFittingVisibleScreen(frame.size, visibleFrame: visibleFrame)
        let width = size.width
        let height = size.height
        let centeredX = visibleFrame.midX - width / 2
        let centeredY = visibleFrame.midY - height / 2
        let x = min(max(centeredX, visibleFrame.minX + screenMargin), visibleFrame.maxX - screenMargin - width)
        let y = min(max(centeredY, visibleFrame.minY + screenMargin), visibleFrame.maxY - screenMargin - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    static func constrainedFrameFittingVisibleScreen(_ frame: NSRect, visibleFrame: NSRect) -> NSRect {
        let size = sizeFittingVisibleScreen(frame.size, visibleFrame: visibleFrame)
        let x = clampedOrigin(frame.minX, length: size.width, min: visibleFrame.minX, max: visibleFrame.maxX)
        let y = clampedOrigin(frame.minY, length: size.height, min: visibleFrame.minY, max: visibleFrame.maxY)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private static func sizeFittingVisibleScreen(_ size: NSSize, visibleFrame: NSRect) -> NSSize {
        NSSize(
            width: min(size.width, max(1, visibleFrame.width - screenMargin * 2)),
            height: min(size.height, max(1, visibleFrame.height - screenMargin * 2))
        )
    }

    private static func clampedOrigin(_ origin: CGFloat, length: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        let lowerBound = min + screenMargin
        let upperBound = max - screenMargin - length
        guard upperBound >= lowerBound else {
            return min + (max - min - length) / 2
        }
        return Swift.min(Swift.max(origin, lowerBound), upperBound)
    }

    private static func placeWindowForOpening(_ window: NSWindow) {
        let visibleFrame = targetVisibleFrame(for: window)
        guard let visibleFrame else {
            window.center()
            return
        }
        window.setFrame(
            openingFrameFittingVisibleScreen(window.frame, visibleFrame: visibleFrame),
            display: false
        )
    }

    private static func constrainWindowToVisibleScreen(_ window: NSWindow) {
        let visibleFrame = window.screen?.visibleFrame ?? targetVisibleFrame(for: window)
        guard let visibleFrame else {
            window.center()
            return
        }
        window.setFrame(
            constrainedFrameFittingVisibleScreen(window.frame, visibleFrame: visibleFrame),
            display: true
        )
    }

    private static func targetVisibleFrame(for window: NSWindow?) -> NSRect? {
        targetScreen(for: window)?.visibleFrame
    }

    private static func targetScreen(for window: NSWindow?) -> NSScreen? {
        let application = NSApplication.shared
        for candidate in [application.keyWindow, application.mainWindow] {
            guard let candidate else { continue }
            if let window, candidate === window { continue }
            if let screen = candidate.screen {
                return screen
            }
        }
        return window?.screen ?? NSScreen.main
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class InsightsWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        let constrainedFrame = super.constrainFrameRect(frameRect, to: screen)
        guard let visibleFrame = screen?.visibleFrame ?? self.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            return constrainedFrame
        }
        return InsightsWindowController.constrainedFrameFittingVisibleScreen(
            constrainedFrame,
            visibleFrame: visibleFrame
        )
    }

    override func sendEvent(_ event: NSEvent) {
        if shouldClose(for: event) {
            close()
            return
        }

        super.sendEvent(event)
    }

    private func shouldClose(for event: NSEvent) -> Bool {
        event.type == .keyDown
            && event.keyCode == UInt16(kVK_Escape)
            && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }
}

@MainActor
private final class InsightsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let index: FileIndex
    private let defaults: UserDefaults
    private let clearCachedIndexHandler: () throws -> Void

    private let scrollView = NSScrollView()
    private let contentView = FlippedView()
    private let overviewTilesContainer = NSView()
    private let storageTitleLabel = NSTextField(labelWithString: "")
    private let treemapView = InsightsTreemapView()
    private let activityChartView = InsightsBarChartView()
    private let rootsTableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "Loading insights...")
    private let revealDataFolderButton = NSButton()
    private let clearCachedIndexButton = NSButton()
    private let copyReportButton = NSButton()
    private let saveReportButton = NSButton()
    private let storageSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let performanceSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let healthTilesContainer = NSView()
    private let lifetimeSummaryLabel = NSTextField(wrappingLabelWithString: "")

    private var refreshTimer: Timer?
    private var latestSnapshot: IndexInsightsSnapshot?
    private var displayedRoots: [IndexRootInsight] = []
    private var unrepresentedRootPaths = Set<String>()
    private var rootAccessStatuses: [String: InsightsRootAccessStatus] = [:]
    private var isRefreshingInsights = false
    private var overviewTileConstraints: [NSLayoutConstraint] = []
    private var healthTileConstraints: [NSLayoutConstraint] = []

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
        view = ThemedBackgroundView(frame: NSRect(origin: .zero, size: InsightsWindowController.defaultContentSize))
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
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.textColor = .labelColor

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 13, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        allowHorizontalCompression(statusLabel)

        configureIconButton(revealDataFolderButton, title: "Reveal Data Folder", symbol: "folder", action: #selector(revealDataFolder(_:)))
        configureIconButton(clearCachedIndexButton, title: "Clear Cached Index...", symbol: "trash", action: #selector(clearCachedIndex(_:)))
        configureIconButton(copyReportButton, title: "Copy Diagnostics Report", symbol: "doc.on.doc", action: #selector(copyDiagnosticsReport(_:)))
        configureIconButton(saveReportButton, title: "Save Diagnostics Report...", symbol: "square.and.arrow.down", action: #selector(saveDiagnosticsReport(_:)))

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

        overviewTilesContainer.translatesAutoresizingMaskIntoConstraints = false

        let overviewCard = makeCard(containing: overviewTilesContainer)

        let storageLabel = makeSectionLabel("Storage")
        storageTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        storageTitleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        storageTitleLabel.textColor = .labelColor
        storageTitleLabel.lineBreakMode = .byTruncatingTail
        allowHorizontalCompression(storageTitleLabel)
        treemapView.translatesAutoresizingMaskIntoConstraints = false
        storageSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        storageSummaryLabel.font = .systemFont(ofSize: 12)
        storageSummaryLabel.textColor = .secondaryLabelColor
        storageSummaryLabel.lineBreakMode = .byWordWrapping
        storageSummaryLabel.maximumNumberOfLines = 2
        allowHorizontalCompression(storageSummaryLabel)
        let storageStack = verticalStack([storageTitleLabel, treemapView, storageSummaryLabel], spacing: 6)
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
        performanceSummaryLabel.maximumNumberOfLines = 2
        allowHorizontalCompression(performanceSummaryLabel)
        let activityCard = makeCard(containing: verticalStack([activityChartView, performanceSummaryLabel], spacing: 8))

        let healthLabel = makeSectionLabel("Performance & Health")
        healthTilesContainer.translatesAutoresizingMaskIntoConstraints = false
        lifetimeSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        lifetimeSummaryLabel.font = .systemFont(ofSize: 12)
        lifetimeSummaryLabel.textColor = .secondaryLabelColor
        lifetimeSummaryLabel.lineBreakMode = .byWordWrapping
        lifetimeSummaryLabel.maximumNumberOfLines = 2
        allowHorizontalCompression(lifetimeSummaryLabel)
        let healthContentView = NSView()
        healthContentView.translatesAutoresizingMaskIntoConstraints = false
        healthContentView.addSubview(healthTilesContainer)
        healthContentView.addSubview(lifetimeSummaryLabel)
        NSLayoutConstraint.activate([
            healthTilesContainer.topAnchor.constraint(equalTo: healthContentView.topAnchor),
            healthTilesContainer.leadingAnchor.constraint(equalTo: healthContentView.leadingAnchor),
            healthTilesContainer.trailingAnchor.constraint(equalTo: healthContentView.trailingAnchor),
            healthTilesContainer.heightAnchor.constraint(equalToConstant: 128),

            lifetimeSummaryLabel.topAnchor.constraint(equalTo: healthTilesContainer.bottomAnchor, constant: 8),
            lifetimeSummaryLabel.leadingAnchor.constraint(equalTo: healthContentView.leadingAnchor),
            lifetimeSummaryLabel.trailingAnchor.constraint(equalTo: healthContentView.trailingAnchor),
            lifetimeSummaryLabel.bottomAnchor.constraint(equalTo: healthContentView.bottomAnchor)
        ])
        let healthCard = makeCard(containing: healthContentView)

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
            healthCard
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

            titleLabel.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 26),

            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -26),

            buttonStack.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            buttonStack.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -26),

            overviewCard.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            overviewCard.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            overviewCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -26),
            overviewTilesContainer.heightAnchor.constraint(equalToConstant: 132),

            storageLabel.topAnchor.constraint(equalTo: overviewCard.bottomAnchor, constant: 16),
            storageLabel.leadingAnchor.constraint(equalTo: overviewCard.leadingAnchor),

            storageCard.topAnchor.constraint(equalTo: storageLabel.bottomAnchor, constant: 8),
            storageCard.leadingAnchor.constraint(equalTo: overviewCard.leadingAnchor),
            storageCard.widthAnchor.constraint(equalTo: overviewCard.widthAnchor, multiplier: 0.48),
            treemapView.heightAnchor.constraint(equalToConstant: 124),

            rootsLabel.topAnchor.constraint(equalTo: storageLabel.topAnchor),
            rootsLabel.leadingAnchor.constraint(equalTo: storageCard.trailingAnchor, constant: 18),

            rootsCard.topAnchor.constraint(equalTo: rootsLabel.bottomAnchor, constant: 8),
            rootsCard.leadingAnchor.constraint(equalTo: rootsLabel.leadingAnchor),
            rootsCard.trailingAnchor.constraint(equalTo: overviewCard.trailingAnchor),
            rootsCard.heightAnchor.constraint(equalTo: storageCard.heightAnchor),
            rootsScrollView.heightAnchor.constraint(equalToConstant: 178),

            activityLabel.topAnchor.constraint(equalTo: storageCard.bottomAnchor, constant: 16),
            activityLabel.leadingAnchor.constraint(equalTo: overviewCard.leadingAnchor),

            activityCard.topAnchor.constraint(equalTo: activityLabel.bottomAnchor, constant: 8),
            activityCard.leadingAnchor.constraint(equalTo: overviewCard.leadingAnchor),
            activityCard.widthAnchor.constraint(equalTo: storageCard.widthAnchor),
            activityChartView.heightAnchor.constraint(equalToConstant: 104),

            healthLabel.topAnchor.constraint(equalTo: activityLabel.topAnchor),
            healthLabel.leadingAnchor.constraint(equalTo: activityCard.trailingAnchor, constant: 18),

            healthCard.topAnchor.constraint(equalTo: healthLabel.bottomAnchor, constant: 8),
            healthCard.leadingAnchor.constraint(equalTo: healthLabel.leadingAnchor),
            healthCard.trailingAnchor.constraint(equalTo: overviewCard.trailingAnchor),
            healthCard.heightAnchor.constraint(equalTo: activityCard.heightAnchor),
            healthCard.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18)
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
        displayedRoots = InsightsRootDisplay.roots(
            snapshotRoots: snapshot.roots,
            configuredRootPaths: configuredIndexedRootPaths()
        )
        rootAccessStatuses = InsightsRootAccessStatus.statuses(for: displayedRoots)
        unrepresentedRootPaths = Set(displayedRoots.filter(InsightsRootDisplay.isUnrepresented).map(\.path))
        sortDisplayedRoots()

        statusLabel.stringValue = "\(snapshot.stats.status) - updated \(relativeDateString(snapshot.stats.lastUpdated))"
        clearCachedIndexButton.isEnabled = snapshot.health.canClearCachedIndex

        rebuildOverviewGrid(snapshot, displayedRootCount: displayedRoots.count)
        treemapView.roots = displayedRoots
        activityChartView.buckets = Array(snapshot.usage.dailyBuckets.suffix(30))
        rootsTableView.reloadData()

        storageTitleLabel.stringValue = storageTitleText(roots: displayedRoots)
        storageSummaryLabel.stringValue = storageSummaryText(
            snapshot,
            displayedRoots: displayedRoots,
            accessStatuses: rootAccessStatuses,
            activePlaceholder: InsightsRootDisplay.activePlaceholderLabel(for: snapshot.stats)
        )
        performanceSummaryLabel.stringValue = "Searches: \(snapshot.usage.allTimeSearches.completed.formatted()) completed, \(snapshot.usage.allTimeSearches.fallbackScans.formatted()) full fallback scans, average latency \(durationString(snapshot.usage.allTimeSearches.averageLatency))."
        rebuildHealthGrid(snapshot)
        lifetimeSummaryLabel.stringValue = lifetimeText(snapshot)
    }

    private func rebuildOverviewGrid(_ snapshot: IndexInsightsSnapshot, displayedRootCount: Int) {
        NSLayoutConstraint.deactivate(overviewTileConstraints)
        overviewTileConstraints.removeAll()
        overviewTilesContainer.subviews.forEach { $0.removeFromSuperview() }

        let tiles = [
            makeMetricTile(title: "Tracked Files", value: snapshot.stats.indexedCount.formatted(), detail: "\(displayedRootCount) roots"),
            makeMetricTile(title: "ATT Data", value: byteString(snapshot.storage.totalATTDataBytes), detail: "Index \(byteString(snapshot.storage.indexPackageBytes))"),
            makeMetricTile(title: "Searches", value: snapshot.usage.allTimeSearches.completed.formatted(), detail: "\(snapshot.usage.allTimeSearches.fallbackScans.formatted()) fallbacks"),
            makeMetricTile(title: "Index Updates", value: snapshot.usage.health.incrementalRefreshBatches.formatted(), detail: "\(snapshot.usage.health.fullRebuilds.formatted()) rebuilds"),
            makeMetricTile(title: "Memory", value: byteString(snapshot.usage.dailyBuckets.last?.memory.latestBytes ?? 0), detail: "latest sample"),
            makeMetricTile(title: "Launches", value: snapshot.lifetime.launchCount.formatted(), detail: dateOnlyString(snapshot.lifetime.firstLaunchDate))
        ]

        overviewTileConstraints = layoutTileGrid(tiles, in: overviewTilesContainer, columns: 3, rowGap: 8, columnGap: 8)
    }

    private func rebuildHealthGrid(_ snapshot: IndexInsightsSnapshot) {
        let searches = snapshot.usage.allTimeSearches
        let health = snapshot.usage.health
        let failureCount = health.snapshotLoadFailures + health.persistFailures
        let healthValue = failureCount == 0 ? "OK" : failureCount.formatted()
        let healthDetail = failureCount == 0
            ? "jobs \(snapshot.health.activeIndexJobs) · schema \(snapshot.health.schemaVersion)"
            : "snapshot \(health.snapshotLoadFailures.formatted()) · persist \(health.persistFailures.formatted())"

        let tiles = [
            makeHealthTile(
                title: "Search Path",
                value: "\(searches.indexedCandidateSearches.formatted()) fast",
                detail: "\(searches.fallbackScans.formatted()) fallbacks"
            ),
            makeHealthTile(
                title: "Latency",
                value: durationString(searches.averageLatency),
                detail: "max \(durationString(searches.maxLatency))"
            ),
            makeHealthTile(
                title: "Rows Examined",
                value: searches.candidateRowsExamined.formatted(),
                detail: "\(searches.scannedRowsExamined.formatted()) full scan"
            ),
            makeHealthTile(
                title: "Index Health",
                value: healthValue,
                detail: healthDetail,
                isWarning: failureCount > 0
            )
        ]

        healthTileConstraints = layoutTileGrid(tiles, in: healthTilesContainer, columns: 2, rowGap: 8, columnGap: 8)
    }

    private func layoutTileGrid(
        _ tiles: [NSView],
        in container: NSView,
        columns: Int,
        rowGap: CGFloat,
        columnGap: CGFloat
    ) -> [NSLayoutConstraint] {
        NSLayoutConstraint.deactivate(
            container === overviewTilesContainer ? overviewTileConstraints : healthTileConstraints
        )
        container.subviews.forEach { $0.removeFromSuperview() }

        for tile in tiles {
            tile.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(tile)
        }

        guard !tiles.isEmpty, columns > 0 else { return [] }

        var constraints: [NSLayoutConstraint] = []
        let rows = Int(ceil(Double(tiles.count) / Double(columns)))
        let firstTile = tiles[0]

        for (index, tile) in tiles.enumerated() {
            let row = index / columns
            let column = index % columns

            if row == 0 {
                constraints.append(tile.topAnchor.constraint(equalTo: container.topAnchor))
            } else {
                let above = tiles[index - columns]
                constraints.append(tile.topAnchor.constraint(equalTo: above.bottomAnchor, constant: rowGap))
            }

            if row == rows - 1 {
                constraints.append(tile.bottomAnchor.constraint(equalTo: container.bottomAnchor))
            }

            if column == 0 {
                constraints.append(tile.leadingAnchor.constraint(equalTo: container.leadingAnchor))
            } else {
                let previous = tiles[index - 1]
                constraints.append(tile.leadingAnchor.constraint(equalTo: previous.trailingAnchor, constant: columnGap))
                constraints.append(tile.widthAnchor.constraint(equalTo: previous.widthAnchor))
            }

            if column == columns - 1 || index == tiles.count - 1 {
                constraints.append(tile.trailingAnchor.constraint(equalTo: container.trailingAnchor))
            }

            if tile !== firstTile {
                constraints.append(tile.heightAnchor.constraint(equalTo: firstTile.heightAnchor))
            }
        }

        NSLayoutConstraint.activate(constraints)
        return constraints
    }

    private func configureRootsTable() {
        rootsTableView.translatesAutoresizingMaskIntoConstraints = false
        rootsTableView.headerView = NSTableHeaderView()
        rootsTableView.rowHeight = 26
        rootsTableView.usesAlternatingRowBackgroundColors = false
        rootsTableView.dataSource = self
        rootsTableView.delegate = self

        for column in [
            makeTableColumn("root", title: "Root", width: 170),
            makeTableColumn("files", title: "Files", width: 90),
            makeTableColumn("content", title: "Content", width: 82),
            makeTableColumn("estimate", title: "Index Est.", width: 82)
        ] {
            rootsTableView.addTableColumn(column)
        }
    }

    private func storageTitleText(roots: [IndexRootInsight]) -> String {
        let rootsWithData = roots.filter { root in
            root.trackedFileCount > 0 || root.directoryCount > 0 || root.pathByteWeight > 0
        }.count
        if roots.isEmpty {
            return "Estimated index package share by root"
        }
        return "Estimated index package share by root (\(rootsWithData) of \(roots.count) with indexed data)"
    }

    private func storageSummaryText(
        _ snapshot: IndexInsightsSnapshot,
        displayedRoots: [IndexRootInsight],
        accessStatuses: [String: InsightsRootAccessStatus],
        activePlaceholder: String?
    ) -> String {
        var parts = [
            "ATT data \(byteString(snapshot.storage.totalATTDataBytes)); index package \(byteString(snapshot.storage.indexPackageBytes)).",
            "Counts are exact; package bytes are estimated from indexed path weight."
        ]

        let unrepresentedRoots = displayedRoots.filter(InsightsRootDisplay.isUnrepresented).count
        let noRowRoots = displayedRoots.filter(InsightsRootDisplay.hasNoIndexedRows).count
        let inaccessibleRoots = displayedRoots.filter { root in
            InsightsRootDisplay.hasNoIndexedRows(root)
                && accessStatuses[root.path]?.preventsIndexing == true
        }.count
        let pendingRoots = activePlaceholder == nil ? 0 : displayedRoots.filter { root in
            InsightsRootDisplay.hasNoIndexedRows(root)
                && accessStatuses[root.path]?.preventsIndexing != true
        }.count

        if inaccessibleRoots > 0 {
            parts.append("\(inaccessibleRoots) configured root\(inaccessibleRoots == 1 ? " is" : "s are") not readable by ATT; grant access, then rebuild.")
        } else if pendingRoots > 0, let activePlaceholder {
            parts.append("\(pendingRoots) root\(pendingRoots == 1 ? " is" : "s are") still \(activePlaceholder.lowercased()).")
        } else if unrepresentedRoots > 0 {
            parts.append("\(unrepresentedRoots) configured root\(unrepresentedRoots == 1 ? " is" : "s are") not represented in the current index snapshot.")
        } else if noRowRoots > 0 {
            parts.append("\(noRowRoots) root\(noRowRoots == 1 ? " has" : "s have") no indexed rows; check access, exclusions, or whether they are empty.")
        } else {
            parts.append(storageMeasurementText(snapshot.storage))
        }

        return parts.joined(separator: " ")
    }

    private func storageMeasurementText(_ storage: IndexStorageInsights) -> String {
        if storage.isMeasuring {
            return "Full data-folder sizing is still measuring."
        }
        guard let measuredAt = storage.measuredAt else {
            return "Showing package sizing until background measurement finishes."
        }
        return "Storage measured \(relativeDateString(measuredAt))."
    }

    private func configuredIndexedRootPaths() -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for url in AppSettings.indexedRoots(defaults: defaults) {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            paths.append(path)
        }
        return paths
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
        let isUnrepresented = unrepresentedRootPaths.contains(root.path)
        let hasNoIndexedRows = InsightsRootDisplay.hasNoIndexedRows(root)
        let accessStatus = rootAccessStatuses[root.path]
        let hasAccessProblem = hasNoIndexedRows && accessStatus?.preventsIndexing == true
        let activePlaceholder = hasNoIndexedRows && !hasAccessProblem
            ? latestSnapshot.flatMap { InsightsRootDisplay.activePlaceholderLabel(for: $0.stats) }
            : nil
        let cell = NSTextField(labelWithString: "")
        cell.font = identifier == "root" || isUnrepresented
            ? .systemFont(ofSize: 12, weight: identifier == "root" ? .medium : .regular)
            : .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        cell.textColor = hasAccessProblem
            ? .systemOrange
            : (activePlaceholder != nil
                ? .secondaryLabelColor
                : ((isUnrepresented || hasNoIndexedRows) ? .tertiaryLabelColor : (identifier == "root" ? .labelColor : .secondaryLabelColor)))
        cell.lineBreakMode = .byTruncatingMiddle
        if hasAccessProblem {
            cell.toolTip = accessStatus?.tooltip
        } else if let activePlaceholder {
            cell.toolTip = "This configured root has no indexed rows yet because the index is still \(activePlaceholder.lowercased())."
        } else if isUnrepresented {
            cell.toolTip = "This configured root is not represented in the current index snapshot. Rebuild or let indexing finish to count it."
        } else if hasNoIndexedRows {
            cell.toolTip = "No files or folders from this root are in the current index. The folder may be empty, inaccessible, or fully excluded."
        }

        switch identifier {
        case "root":
            cell.stringValue = AppSettings.displayPath(root.path)
            cell.toolTip = (isUnrepresented || hasNoIndexedRows || hasAccessProblem) ? cell.toolTip : root.path
        case "files":
            if hasAccessProblem {
                cell.stringValue = accessStatus?.tableLabel ?? "No access"
            } else if let activePlaceholder {
                cell.stringValue = activePlaceholder
            } else if isUnrepresented {
                cell.stringValue = "Not indexed"
            } else if hasNoIndexedRows {
                cell.stringValue = "No rows"
            } else {
                cell.stringValue = root.trackedFileCount.formatted()
            }
        case "content":
            cell.stringValue = (isUnrepresented || hasNoIndexedRows) ? "-" : byteString(root.indexedContentBytes)
        case "estimate":
            cell.stringValue = (isUnrepresented || hasNoIndexedRows) ? "-" : byteString(root.estimatedIndexBytes)
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

    private func lifetimeText(_ snapshot: IndexInsightsSnapshot) -> String {
        let firstLaunch = dateOnlyString(snapshot.lifetime.firstLaunchDate)
        let versionSeen = dateOnlyString(snapshot.lifetime.currentAppVersionFirstSeenDate)
        let daily = snapshot.usage.dailyBuckets.last
        let memory = daily.map { "Memory today \(byteString($0.memory.dailyMinimumBytes)) - \(byteString($0.memory.dailyMaximumBytes))" } ?? "No memory samples yet"
        return "First launch \(firstLaunch) · launches \(snapshot.lifetime.launchCount.formatted()) · version seen \(versionSeen) · \(memory)"
    }

    private func configureIconButton(_ button: NSButton, title: String, symbol: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageOnly
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    private func makeSectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        allowHorizontalCompression(label)
        return label
    }

    private func makeMetricTile(title: String, value: String, detail: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .left
        allowHorizontalCompression(titleLabel)

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        valueLabel.textColor = .labelColor
        valueLabel.alignment = .left
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.maximumNumberOfLines = 1
        allowHorizontalCompression(valueLabel)

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11, weight: .medium)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .left
        detailLabel.lineBreakMode = .byTruncatingTail
        allowHorizontalCompression(detailLabel)

        let stack = verticalStack([titleLabel, valueLabel, detailLabel], spacing: 2)
        stack.alignment = .leading
        stack.wantsLayer = true
        stack.layer?.cornerRadius = 6
        stack.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        NSLayoutConstraint.activate([
            stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 62)
        ])
        return stack
    }

    private func makeHealthTile(title: String, value: String, detail: String, isWarning: Bool = false) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        allowHorizontalCompression(titleLabel)

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        valueLabel.textColor = isWarning ? .systemOrange : .labelColor
        valueLabel.alignment = .left
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.maximumNumberOfLines = 1
        allowHorizontalCompression(valueLabel)

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 10, weight: .medium)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .left
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        allowHorizontalCompression(detailLabel)

        let stack = verticalStack([titleLabel, valueLabel, detailLabel], spacing: 2)
        stack.alignment = .leading
        stack.wantsLayer = true
        stack.layer?.cornerRadius = 6
        stack.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.42).cgColor
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 9, bottom: 7, right: 9)
        NSLayoutConstraint.activate([
            stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 54)
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
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
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

    private func allowHorizontalCompression(_ view: NSView) {
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
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

enum InsightsRootDisplay {
    static func hasNoIndexedRows(_ root: IndexRootInsight) -> Bool {
        root.trackedFileCount == 0
            && root.directoryCount == 0
            && root.indexedContentBytes == 0
            && root.pathByteWeight == 0
    }

    static func isUnrepresented(_ root: IndexRootInsight) -> Bool {
        root.attributionSource == .estimated
            && hasNoIndexedRows(root)
            && root.estimatedIndexBytes == 0
    }

    static func activePlaceholderLabel(for stats: IndexStats) -> String? {
        if stats.isLoadingSnapshot || stats.phase == .loading {
            return "Loading"
        }
        guard stats.isIndexing else { return nil }

        switch stats.phase {
        case .scanning:
            if stats.isReconciling {
                return "Reconciling"
            }
            if stats.isUpdating {
                return "Updating"
            }
            return "Indexing"
        case .optimizing:
            return "Optimizing"
        case .saving:
            return "Saving"
        case .idle, .ready, .failed, .loading:
            return nil
        }
    }

    static func roots(
        snapshotRoots: [IndexRootInsight],
        configuredRootPaths: [String]
    ) -> [IndexRootInsight] {
        guard !configuredRootPaths.isEmpty else {
            return snapshotRoots
        }

        let snapshotByPath = Dictionary(uniqueKeysWithValues: snapshotRoots.map { ($0.path, $0) })
        var seen = Set<String>()
        var roots: [IndexRootInsight] = []
        roots.reserveCapacity(max(snapshotRoots.count, configuredRootPaths.count))

        for path in configuredRootPaths where seen.insert(path).inserted {
            if let root = snapshotByPath[path] {
                roots.append(root)
            } else {
                roots.append(IndexRootInsight(
                    path: path,
                    trackedFileCount: 0,
                    directoryCount: 0,
                    hiddenCount: 0,
                    indexedContentBytes: 0,
                    pathByteWeight: 0,
                    estimatedIndexBytes: 0,
                    attributionSource: .estimated
                ))
            }
        }

        for root in snapshotRoots where seen.insert(root.path).inserted {
            roots.append(root)
        }

        return roots
    }
}

enum InsightsRootAccessStatus: Equatable {
    case readable
    case notReadable
    case missing
    case notDirectory

    var preventsIndexing: Bool {
        self != .readable
    }

    var tableLabel: String {
        switch self {
        case .readable:
            "No rows"
        case .notReadable:
            "No access"
        case .missing:
            "Missing"
        case .notDirectory:
            "Not folder"
        }
    }

    var tooltip: String {
        switch self {
        case .readable:
            "No files or folders from this root are in the current index. The folder may be empty or fully excluded."
        case .notReadable:
            "AllTheThings cannot read this folder. Grant folder access or Full Disk Access, then rebuild the index."
        case .missing:
            "This configured folder no longer exists. Remove it or restore it, then rebuild the index."
        case .notDirectory:
            "This configured root is not a folder. Remove it or choose a folder, then rebuild the index."
        }
    }

    static func statuses(for roots: [IndexRootInsight]) -> [String: InsightsRootAccessStatus] {
        Dictionary(uniqueKeysWithValues: roots
            .filter(InsightsRootDisplay.hasNoIndexedRows)
            .map { ($0.path, status(for: $0.path)) })
    }

    static func status(for path: String, fileManager: FileManager = .default) -> InsightsRootAccessStatus {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .missing
        }
        guard isDirectory.boolValue else {
            return .notDirectory
        }
        guard canEnumerateDirectory(at: path) else {
            return .notReadable
        }
        return .readable
    }

    private static func canEnumerateDirectory(at path: String) -> Bool {
        path.withCString { representation -> Bool in
            let descriptor = open(representation, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { return false }
            guard let stream = fdopendir(descriptor) else {
                close(descriptor)
                return false
            }
            defer { closedir(stream) }
            errno = 0
            _ = readdir(stream)
            return errno == 0
        }
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

        let weights = roots.map(Self.layoutWeight(for:))
        let items = InsightsTreemapLayout.layout(weights: weights, in: bounds.insetBy(dx: 1, dy: 1))
        guard !items.isEmpty else {
            drawEmpty("No indexed data yet")
            return
        }

        let total = items.reduce(UInt64(0)) { $0 &+ weights[$1.index] }
        let labels = Self.compactLabels(for: roots.map(\.path))
        let palette: [NSColor] = [.systemBlue, .systemGreen, .systemPink, .systemOrange, .systemPurple, .systemTeal, .systemIndigo]

        for item in items {
            let root = roots[item.index]
            let rect = item.rect
            let color = palette[item.index % palette.count]
            let insetX = rect.width > 4 ? CGFloat(2) : 0
            let insetY = rect.height > 4 ? CGFloat(2) : 0
            let fillRect = rect.insetBy(dx: insetX, dy: insetY)
            guard fillRect.width > 0, fillRect.height > 0 else { continue }
            let radius = min(CGFloat(5), fillRect.width / 2, fillRect.height / 2)
            color.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
            if fillRect.width > 3, fillRect.height > 3 {
                NSColor.white.withAlphaComponent(0.22).setStroke()
                let strokeInset = min(CGFloat(0.5), fillRect.width / 5, fillRect.height / 5)
                let strokeRect = fillRect.insetBy(dx: strokeInset, dy: strokeInset)
                let strokeRadius = min(radius, strokeRect.width / 2, strokeRect.height / 2)
                NSBezierPath(roundedRect: strokeRect, xRadius: strokeRadius, yRadius: strokeRadius).stroke()
            }

            if rect.width > 84, rect.height > 42 {
                let percent = total == 0
                    ? "0%"
                    : "\(Int((Double(weights[item.index]) / Double(total) * 100).rounded()))%"
                let label = "\(labels[item.index])\n\(percent) - \(root.trackedFileCount.formatted()) files"
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

    nonisolated private static func layoutWeight(for root: IndexRootInsight) -> UInt64 {
        if root.estimatedIndexBytes > 0 {
            return root.estimatedIndexBytes
        }
        if root.pathByteWeight > 0 {
            return root.pathByteWeight
        }
        return UInt64(max(root.trackedFileCount + root.directoryCount, 0))
    }

    nonisolated private static func compactLabels(for paths: [String]) -> [String] {
        let components = paths.map { path -> [String] in
            let parts = path.split(separator: "/").map(String.init)
            return parts.isEmpty ? [path] : parts
        }
        let maxDepth = max(components.map(\.count).max() ?? 1, 1)

        for depth in 1...maxDepth {
            let labels = components.map { parts -> String in
                let suffix = parts.suffix(depth)
                return suffix.isEmpty ? "/" : suffix.joined(separator: "/")
            }
            if Set(labels).count == labels.count {
                return labels
            }
        }

        return paths
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

struct InsightsTreemapLayoutItem: Equatable {
    let index: Int
    let rect: NSRect
}

enum InsightsTreemapLayout {
    private static let minimumVisibleSpan: CGFloat = 1

    static func layout(weights: [UInt64], in bounds: NSRect) -> [InsightsTreemapLayoutItem] {
        guard bounds.width > 0, bounds.height > 0 else { return [] }

        let activeWeights = weights.enumerated().filter { $0.element > 0 }
        var remainingWeight = activeWeights.reduce(UInt64(0)) { $0 &+ $1.element }
        guard remainingWeight > 0 else { return [] }

        var remaining = bounds
        var items: [InsightsTreemapLayoutItem] = []
        items.reserveCapacity(activeWeights.count)

        for (offset, entry) in activeWeights.enumerated() {
            guard remaining.width > 0, remaining.height > 0 else { break }

            let isLast = offset == activeWeights.count - 1
            let remainingItemCount = activeWeights.count - offset
            let rect: NSRect
            if remaining.width >= remaining.height {
                let span = Self.visibleSpan(
                    totalSpan: remaining.width,
                    remainingItemCount: remainingItemCount,
                    entryWeight: entry.element,
                    remainingWeight: remainingWeight,
                    isLast: isLast
                )
                let width = isLast
                    ? remaining.width
                    : span
                rect = NSRect(x: remaining.minX, y: remaining.minY, width: width, height: remaining.height)
                remaining.origin.x += width
                remaining.size.width -= width
            } else {
                let span = Self.visibleSpan(
                    totalSpan: remaining.height,
                    remainingItemCount: remainingItemCount,
                    entryWeight: entry.element,
                    remainingWeight: remainingWeight,
                    isLast: isLast
                )
                let height = isLast
                    ? remaining.height
                    : span
                rect = NSRect(x: remaining.minX, y: remaining.minY, width: remaining.width, height: height)
                remaining.origin.y += height
                remaining.size.height -= height
            }

            items.append(InsightsTreemapLayoutItem(index: entry.offset, rect: rect))
            remainingWeight = remainingWeight > entry.element ? remainingWeight - entry.element : 0
        }

        return items
    }

    private static func visibleSpan(
        totalSpan: CGFloat,
        remainingItemCount: Int,
        entryWeight: UInt64,
        remainingWeight: UInt64,
        isLast: Bool
    ) -> CGFloat {
        guard !isLast else { return totalSpan }
        let proportional = floor(totalSpan * CGFloat(Double(entryWeight) / Double(remainingWeight)))
        let canReserveMinimums = totalSpan >= CGFloat(remainingItemCount) * minimumVisibleSpan
        guard canReserveMinimums else {
            return min(totalSpan, max(1, proportional))
        }

        let reservedForLater = CGFloat(remainingItemCount - 1) * minimumVisibleSpan
        let available = max(minimumVisibleSpan, totalSpan - reservedForLater)
        return min(available, max(minimumVisibleSpan, proportional))
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
        let plot = InsightsActivityChartLayout.plotRect(in: bounds)
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

        drawLegend(in: InsightsActivityChartLayout.legendRect(in: bounds))
    }

    private func drawBar(x: CGFloat, width: CGFloat, height: CGFloat, color: NSColor, plot: NSRect) {
        guard height > 0 else { return }
        color.setFill()
        let rect = NSRect(x: x, y: plot.maxY - height, width: width, height: height)
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
    }

    private func drawLegend(in rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        var x = rect.minX
        for item in InsightsActivityChartLayout.legendItems {
            item.color.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: x, y: rect.minY + 3, width: 8, height: 8),
                xRadius: 2,
                yRadius: 2
            ).fill()
            x += 12
            item.title.draw(at: NSPoint(x: x, y: rect.minY), withAttributes: attributes)
            x += item.title.size(withAttributes: attributes).width + 14
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

enum InsightsActivityChartLayout {
    static let inset = NSEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
    static let legendHeight: CGFloat = 14
    static let legendGap: CGFloat = 8
    static let legendItems: [(title: String, color: NSColor)] = [
        ("Searches", .systemBlue),
        ("File actions", .systemGreen.withAlphaComponent(0.75)),
        ("Index updates", .systemOrange.withAlphaComponent(0.8))
    ]

    static func plotRect(in bounds: NSRect) -> NSRect {
        let content = bounds.insetBy(dx: inset.left, dy: 0)
        let y = bounds.minY + inset.top
        let bottomReserved = inset.bottom + legendHeight + legendGap
        return NSRect(
            x: content.minX,
            y: y,
            width: max(0, content.width),
            height: max(0, bounds.height - inset.top - bottomReserved)
        )
    }

    static func legendRect(in bounds: NSRect) -> NSRect {
        let plot = plotRect(in: bounds)
        return NSRect(
            x: plot.minX,
            y: plot.maxY + legendGap,
            width: plot.width,
            height: legendHeight
        )
    }
}
