import AppKit
import ATTCore
import Carbon.HIToolbox
import Darwin

@MainActor
final class InsightsWindowController: NSWindowController {
    static let defaultContentSize = NSSize(width: 900, height: 600)
    static let minimumContentSize = NSSize(width: 720, height: 500)
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
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Insights"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.canHide = true
        window.isRestorable = false
        window.contentMinSize = Self.clampedContentSize(
            Self.minimumContentSize,
            visibleFrame: initialVisibleFrame
        )
        window.contentViewController = viewController
        window.setContentSize(contentSize)
        Self.placeWindowForOpening(window)

        super.init(window: window)
        viewController.installTitlebarTabs(in: window)
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

private enum InsightsTab: Int, CaseIterable {
    case summary
    case index
    case activity

    var title: String {
        switch self {
        case .summary:
            "Summary"
        case .index:
            "Index"
        case .activity:
            "Activity"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .summary:
            "Insights.SummaryPage"
        case .index:
            "Insights.IndexPage"
        case .activity:
            "Insights.ActivityPage"
        }
    }
}

private struct InsightsFact {
    let title: String
    let value: String
    let tooltip: String?

    init(_ title: String, _ value: String, tooltip: String? = nil) {
        self.title = title
        self.value = value
        self.tooltip = tooltip
    }
}

private enum InsightsRoutePresentation {
    static func previewDisplayCounters(_ counters: SearchUsageCounters) -> SearchUsageCounters {
        var displayCounters = counters
        displayCounters.routeCounts[.applicationCatalog] = nil
        displayCounters.routeLatencyTotals[.applicationCatalog] = nil
        return displayCounters
    }
}

@MainActor
private final class InsightsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let index: FileIndex
    private let defaults: UserDefaults
    private let clearCachedIndexHandler: () throws -> Void

    private let contentView = FlippedView()
    private let overviewTilesContainer = NSView()
    private let tabControl = NSSegmentedControl(
        labels: InsightsTab.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let tabContentView = NSView()
    private let queryRouteView = InsightsRouteMixView()
    private let queryRouteGroupsStack = NSStackView()
    private let storageTitleLabel = NSTextField(labelWithString: "")
    private let storageFactsStack = NSStackView()
    private let treemapView = InsightsTreemapView()
    private let activityChartView = InsightsBarChartView()
    private let activityFactsStack = NSStackView()
    private let rootsTableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "Loading insights...")
    private let revealDataFolderButton = NSButton()
    private let clearCachedIndexButton = NSButton()
    private let copyReportButton = NSButton()
    private let saveReportButton = NSButton()
    private let titlebarActionStack = NSStackView()
    private let healthTilesContainer = NSView()
    private let lifetimeFactsStack = NSStackView()

    private var refreshTimer: Timer?
    private var latestSnapshot: IndexInsightsSnapshot?
    private var displayedRoots: [IndexRootInsight] = []
    private var unrepresentedRootPaths = Set<String>()
    private var rootAccessStatuses: [String: InsightsRootAccessStatus] = [:]
    private var isRefreshingInsights = false
    private var isViewVisible = false
    private var overviewTileConstraints: [NSLayoutConstraint] = []
    private var healthTileConstraints: [NSLayoutConstraint] = []
    private var tabPages: [InsightsTab: NSView] = [:]
    private var selectedTab: InsightsTab = .summary
    private var activeTabPage: NSView?
    private var activeTabPageConstraints: [NSLayoutConstraint] = []
    private var titlebarTabsInstalled = false

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

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        view = ThemedBackgroundView(frame: NSRect(origin: .zero, size: InsightsWindowController.defaultContentSize))
        buildInterface()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationActivityDidChange(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationActivityDidChange(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        refreshInsights()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        isViewVisible = true
        startPolling()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        isViewVisible = false
        stopPolling()
    }

    private func buildInterface() {
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.setAccessibilityIdentifier("Insights.ContentView")

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

        titlebarActionStack.translatesAutoresizingMaskIntoConstraints = false
        titlebarActionStack.orientation = .horizontal
        titlebarActionStack.alignment = .centerY
        titlebarActionStack.spacing = 8
        titlebarActionStack.setAccessibilityIdentifier("Insights.TitlebarActions")
        if titlebarActionStack.arrangedSubviews.isEmpty {
            for button in [
                revealDataFolderButton,
                clearCachedIndexButton,
                copyReportButton,
                saveReportButton
            ] {
                titlebarActionStack.addArrangedSubview(button)
            }
        }

        tabControl.translatesAutoresizingMaskIntoConstraints = false
        tabControl.segmentStyle = .separated
        tabControl.controlSize = .regular
        tabControl.font = .systemFont(ofSize: 13, weight: .medium)
        for segment in 0..<tabControl.segmentCount {
            tabControl.setWidth(96, forSegment: segment)
        }
        tabControl.target = self
        tabControl.action = #selector(tabSelectionDidChange(_:))
        tabControl.selectedSegment = selectedTab.rawValue
        tabControl.setAccessibilityIdentifier("Insights.TabControl")

        tabContentView.translatesAutoresizingMaskIntoConstraints = false

        configureFactsStack(storageFactsStack)
        configureFactsStack(activityFactsStack)
        configureFactsStack(lifetimeFactsStack)

        overviewTilesContainer.translatesAutoresizingMaskIntoConstraints = false
        overviewTilesContainer.setAccessibilityIdentifier("Insights.SummaryTiles")

        configureRowsStack(queryRouteGroupsStack)
        queryRouteView.translatesAutoresizingMaskIntoConstraints = false
        queryRouteView.setAccessibilityIdentifier("Insights.QueryRouteChart")
        let queryTitleLabel = makePanelTitleLabel("Search Routing")
        queryTitleLabel.setAccessibilityIdentifier("Insights.QueryTitleLabel")
        queryTitleLabel.alignment = .center
        let queryFactsTable = makeFactTable(
            containing: queryRouteGroupsStack,
            accessibilityIdentifier: "Insights.QueryRouteFactsTable"
        )
        replaceQueryRouteGroups(initial: SearchUsageCounters(), refined: SearchUsageCounters())
        let queryPanelStack = verticalStack([
            queryTitleLabel,
            queryRouteView,
            queryFactsTable
        ], spacing: 8)
        queryPanelStack.alignment = .centerX
        NSLayoutConstraint.activate([
            queryTitleLabel.widthAnchor.constraint(equalTo: queryPanelStack.widthAnchor),
            queryRouteView.widthAnchor.constraint(equalToConstant: RouteMatrixLayout.tableWidth),
            queryFactsTable.widthAnchor.constraint(equalToConstant: RouteMatrixLayout.tableWidth)
        ])
        let queryPanel = makeOutlinedPanel(containing: queryPanelStack)
        queryPanel.setAccessibilityIdentifier("Insights.QueryPanel")

        storageTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        storageTitleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        storageTitleLabel.textColor = .labelColor
        storageTitleLabel.lineBreakMode = .byTruncatingTail
        allowHorizontalCompression(storageTitleLabel)
        treemapView.translatesAutoresizingMaskIntoConstraints = false
        treemapView.setAccessibilityIdentifier("Insights.StorageTreemap")
        let storageFactsTable = makeFactTable(
            containing: storageFactsStack,
            accessibilityIdentifier: "Insights.StorageFactsTable"
        )
        let storageChartStack = verticalStack([storageTitleLabel, treemapView], spacing: 8)
        let storageBody = NSView()
        storageBody.translatesAutoresizingMaskIntoConstraints = false
        storageBody.addSubview(storageChartStack)
        storageBody.addSubview(storageFactsTable)
        NSLayoutConstraint.activate([
            storageChartStack.centerYAnchor.constraint(equalTo: storageBody.centerYAnchor),
            storageChartStack.topAnchor.constraint(greaterThanOrEqualTo: storageBody.topAnchor),
            storageChartStack.leadingAnchor.constraint(equalTo: storageBody.leadingAnchor),
            storageChartStack.bottomAnchor.constraint(lessThanOrEqualTo: storageBody.bottomAnchor),
            storageChartStack.trailingAnchor.constraint(equalTo: storageFactsTable.leadingAnchor, constant: -14),
            storageChartStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),

            storageFactsTable.topAnchor.constraint(equalTo: storageBody.topAnchor),
            storageFactsTable.trailingAnchor.constraint(equalTo: storageBody.trailingAnchor),
            storageFactsTable.bottomAnchor.constraint(lessThanOrEqualTo: storageBody.bottomAnchor),
            storageFactsTable.widthAnchor.constraint(equalToConstant: 292)
        ])
        let storageCard = makeOutlinedPanel(containing: storageBody)
        storageCard.setAccessibilityIdentifier("Insights.StorageCard")

        let rootsLabel = makeSectionLabel("Indexed Roots")
        configureRootsTable()
        let rootsScrollView = NSScrollView()
        rootsScrollView.translatesAutoresizingMaskIntoConstraints = false
        rootsScrollView.hasVerticalScroller = true
        rootsScrollView.hasHorizontalScroller = false
        rootsScrollView.borderType = .noBorder
        rootsScrollView.documentView = rootsTableView
        let rootsCard = makeCard(containing: rootsScrollView)
        rootsCard.setAccessibilityIdentifier("Insights.RootsCard")

        activityChartView.translatesAutoresizingMaskIntoConstraints = false
        let activityFactsTable = makeFactTable(
            containing: activityFactsStack,
            accessibilityIdentifier: "Insights.ActivityFactsTable"
        )
        let activityBody = NSView()
        activityBody.translatesAutoresizingMaskIntoConstraints = false
        activityBody.addSubview(activityChartView)
        activityBody.addSubview(activityFactsTable)
        NSLayoutConstraint.activate([
            activityChartView.topAnchor.constraint(equalTo: activityBody.topAnchor),
            activityChartView.leadingAnchor.constraint(equalTo: activityBody.leadingAnchor),
            activityChartView.bottomAnchor.constraint(equalTo: activityBody.bottomAnchor),
            activityChartView.trailingAnchor.constraint(equalTo: activityFactsTable.leadingAnchor, constant: -14),

            activityFactsTable.centerYAnchor.constraint(equalTo: activityBody.centerYAnchor),
            activityFactsTable.topAnchor.constraint(greaterThanOrEqualTo: activityBody.topAnchor),
            activityFactsTable.trailingAnchor.constraint(equalTo: activityBody.trailingAnchor),
            activityFactsTable.bottomAnchor.constraint(lessThanOrEqualTo: activityBody.bottomAnchor),
            activityFactsTable.widthAnchor.constraint(equalToConstant: 292)
        ])
        let activityCard = makeCard(containing: activityBody)
        activityCard.setAccessibilityIdentifier("Insights.ActivityCard")

        healthTilesContainer.translatesAutoresizingMaskIntoConstraints = false
        healthTilesContainer.setAccessibilityIdentifier("Insights.HealthTiles")
        let healthContentView = NSView()
        healthContentView.translatesAutoresizingMaskIntoConstraints = false
        let lifetimeFactsTable = makeFactTable(
            containing: lifetimeFactsStack,
            accessibilityIdentifier: "Insights.HealthFactsTable"
        )
        healthContentView.addSubview(healthTilesContainer)
        healthContentView.addSubview(lifetimeFactsTable)
        NSLayoutConstraint.activate([
            healthTilesContainer.topAnchor.constraint(equalTo: healthContentView.topAnchor),
            healthTilesContainer.leadingAnchor.constraint(equalTo: healthContentView.leadingAnchor),
            healthTilesContainer.bottomAnchor.constraint(equalTo: healthContentView.bottomAnchor),

            lifetimeFactsTable.topAnchor.constraint(equalTo: healthContentView.topAnchor),
            lifetimeFactsTable.leadingAnchor.constraint(equalTo: healthTilesContainer.trailingAnchor, constant: 14),
            lifetimeFactsTable.trailingAnchor.constraint(equalTo: healthContentView.trailingAnchor),
            lifetimeFactsTable.bottomAnchor.constraint(lessThanOrEqualTo: healthContentView.bottomAnchor),
            lifetimeFactsTable.widthAnchor.constraint(equalTo: healthTilesContainer.widthAnchor)
        ])
        let healthCard = makeCard(containing: healthContentView)
        healthCard.setAccessibilityIdentifier("Insights.HealthCard")

        let summaryPage = makePage(accessibilityIdentifier: InsightsTab.summary.accessibilityIdentifier)
        summaryPage.addSubview(overviewTilesContainer)
        summaryPage.addSubview(healthCard)

        let indexPage = makePage(accessibilityIdentifier: InsightsTab.index.accessibilityIdentifier)
        indexPage.addSubview(storageCard)
        indexPage.addSubview(rootsLabel)
        indexPage.addSubview(rootsCard)

        let activityPage = makePage(accessibilityIdentifier: InsightsTab.activity.accessibilityIdentifier)
        activityPage.addSubview(queryPanel)
        activityPage.addSubview(activityCard)

        tabPages = [
            .summary: summaryPage,
            .index: indexPage,
            .activity: activityPage
        ]

        for item in [
            titleLabel,
            statusLabel,
            tabContentView
        ] {
            contentView.addSubview(item)
        }
        view.addSubview(contentView)

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: view.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            titleLabel.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 26),

            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -26),

            tabContentView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 14),
            tabContentView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            tabContentView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -26),
            tabContentView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),

            overviewTilesContainer.topAnchor.constraint(equalTo: summaryPage.topAnchor),
            overviewTilesContainer.leadingAnchor.constraint(equalTo: summaryPage.leadingAnchor),
            overviewTilesContainer.trailingAnchor.constraint(equalTo: summaryPage.trailingAnchor),
            overviewTilesContainer.heightAnchor.constraint(equalToConstant: 190),

            healthCard.topAnchor.constraint(equalTo: overviewTilesContainer.bottomAnchor, constant: 12),
            healthCard.leadingAnchor.constraint(equalTo: summaryPage.leadingAnchor),
            healthCard.trailingAnchor.constraint(equalTo: summaryPage.trailingAnchor),
            healthCard.bottomAnchor.constraint(equalTo: summaryPage.bottomAnchor),

            storageCard.topAnchor.constraint(equalTo: indexPage.topAnchor),
            storageCard.leadingAnchor.constraint(equalTo: indexPage.leadingAnchor),
            storageCard.trailingAnchor.constraint(equalTo: indexPage.trailingAnchor),
            treemapView.heightAnchor.constraint(equalToConstant: 210),

            rootsLabel.topAnchor.constraint(equalTo: storageCard.bottomAnchor, constant: 12),
            rootsLabel.leadingAnchor.constraint(equalTo: indexPage.leadingAnchor),

            rootsCard.topAnchor.constraint(equalTo: rootsLabel.bottomAnchor, constant: 8),
            rootsCard.leadingAnchor.constraint(equalTo: indexPage.leadingAnchor),
            rootsCard.trailingAnchor.constraint(equalTo: indexPage.trailingAnchor),
            rootsCard.bottomAnchor.constraint(equalTo: indexPage.bottomAnchor),
            rootsScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),

            queryPanel.topAnchor.constraint(equalTo: activityPage.topAnchor),
            queryPanel.leadingAnchor.constraint(equalTo: activityPage.leadingAnchor),
            queryPanel.trailingAnchor.constraint(equalTo: activityPage.trailingAnchor),
            queryPanel.heightAnchor.constraint(equalToConstant: 238),
            queryRouteView.heightAnchor.constraint(equalToConstant: 46),

            activityCard.topAnchor.constraint(equalTo: queryPanel.bottomAnchor, constant: 12),
            activityCard.leadingAnchor.constraint(equalTo: activityPage.leadingAnchor),
            activityCard.trailingAnchor.constraint(equalTo: activityPage.trailingAnchor),
            activityCard.bottomAnchor.constraint(lessThanOrEqualTo: activityPage.bottomAnchor),
            activityChartView.heightAnchor.constraint(equalToConstant: 216)
        ])

        showTab(selectedTab)
    }

    func installTitlebarTabs(in window: NSWindow) {
        _ = view
        guard !titlebarTabsInstalled else { return }

        window.titleVisibility = .hidden

        let titlebarGuide = NSLayoutGuide()
        view.addLayoutGuide(titlebarGuide)
        view.addSubview(tabControl)
        view.addSubview(titlebarActionStack)
        NSLayoutConstraint.activate([
            titlebarGuide.topAnchor.constraint(equalTo: view.topAnchor),
            titlebarGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            titlebarGuide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            titlebarGuide.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),

            tabControl.centerXAnchor.constraint(equalTo: titlebarGuide.centerXAnchor),
            tabControl.centerYAnchor.constraint(equalTo: titlebarGuide.centerYAnchor),
            tabControl.leadingAnchor.constraint(greaterThanOrEqualTo: titlebarGuide.leadingAnchor, constant: 140),
            tabControl.trailingAnchor.constraint(lessThanOrEqualTo: titlebarGuide.trailingAnchor, constant: -140),
            tabControl.widthAnchor.constraint(equalToConstant: 288),
            tabControl.heightAnchor.constraint(equalToConstant: 26),

            titlebarActionStack.centerYAnchor.constraint(equalTo: titlebarGuide.centerYAnchor),
            titlebarActionStack.leadingAnchor.constraint(greaterThanOrEqualTo: tabControl.trailingAnchor, constant: 24),
            titlebarActionStack.trailingAnchor.constraint(equalTo: titlebarGuide.trailingAnchor, constant: -26),
            titlebarActionStack.topAnchor.constraint(greaterThanOrEqualTo: titlebarGuide.topAnchor),
            titlebarActionStack.bottomAnchor.constraint(lessThanOrEqualTo: titlebarGuide.bottomAnchor)
        ])
        titlebarTabsInstalled = true
    }

    @objc private func tabSelectionDidChange(_ sender: NSSegmentedControl) {
        guard let tab = InsightsTab(rawValue: sender.selectedSegment) else { return }
        showTab(tab)
    }

    private func showTab(_ tab: InsightsTab) {
        guard let page = tabPages[tab] else { return }
        selectedTab = tab
        tabControl.selectedSegment = tab.rawValue
        guard activeTabPage !== page else { return }

        NSLayoutConstraint.deactivate(activeTabPageConstraints)
        activeTabPageConstraints.removeAll()
        activeTabPage?.removeFromSuperview()

        page.translatesAutoresizingMaskIntoConstraints = false
        tabContentView.addSubview(page)
        activeTabPageConstraints = [
            page.topAnchor.constraint(equalTo: tabContentView.topAnchor),
            page.leadingAnchor.constraint(equalTo: tabContentView.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: tabContentView.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: tabContentView.bottomAnchor)
        ]
        NSLayoutConstraint.activate(activeTabPageConstraints)
        activeTabPage = page
    }

    private func startPolling() {
        guard refreshTimer == nil else { return }
        let interval = refreshInterval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshInsights()
            }
        }
        timer.tolerance = min(5, interval * 0.2)
        refreshTimer = timer
    }

    private func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private var refreshInterval: TimeInterval {
        NSApp.isActive ? 5 : 30
    }

    private func restartPolling() {
        stopPolling()
        guard isViewVisible else { return }
        startPolling()
    }

    @objc private func applicationActivityDidChange(_ notification: Notification) {
        restartPolling()
        if NSApp.isActive {
            refreshInsights()
        }
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
        rebuildQueryPathPanel(snapshot)
        treemapView.roots = displayedRoots
        activityChartView.buckets = Array(snapshot.usage.dailyBuckets.suffix(30))
        rootsTableView.reloadData()

        storageTitleLabel.stringValue = storageTitleText(roots: displayedRoots)
        rebuildStorageFacts(
            snapshot,
            displayedRoots: displayedRoots,
            accessStatuses: rootAccessStatuses,
            activePlaceholder: InsightsRootDisplay.activePlaceholderLabel(for: snapshot.stats)
        )
        rebuildActivityFacts(snapshot)
        rebuildHealthGrid(snapshot)
        rebuildLifetimeFacts(snapshot)
    }

    private func rebuildOverviewGrid(_ snapshot: IndexInsightsSnapshot, displayedRootCount: Int) {
        NSLayoutConstraint.deactivate(overviewTileConstraints)
        overviewTileConstraints.removeAll()
        overviewTilesContainer.subviews.forEach { $0.removeFromSuperview() }

        let tiles = [
            makeMetricTile(title: "Tracked Files", value: snapshot.stats.indexedCount.formatted(), detail: "\(displayedRootCount) roots"),
            makeMetricTile(title: "ATT Data", value: byteString(snapshot.storage.totalATTDataBytes), detail: "Index \(byteString(snapshot.storage.indexPackageBytes))"),
            makeMetricTile(title: "Preview Results", value: snapshot.usage.initialSearches.completed.formatted(), detail: "\(snapshot.usage.initialSearches.cancelled.formatted()) cancelled"),
            makeMetricTile(title: "Index Updates", value: snapshot.usage.health.incrementalRefreshBatches.formatted(), detail: "\(snapshot.usage.health.fullRebuilds.formatted()) rebuilds"),
            makeMetricTile(title: "Memory", value: byteString(snapshot.usage.dailyBuckets.last?.memory.latestBytes ?? 0), detail: "latest sample"),
            makeMetricTile(title: "Launches", value: snapshot.lifetime.launchCount.formatted(), detail: dateOnlyString(snapshot.lifetime.firstLaunchDate))
        ]

        overviewTileConstraints = layoutTileGrid(tiles, in: overviewTilesContainer, columns: 2, rowGap: 8, columnGap: 10)
    }

    private func rebuildQueryPathPanel(_ snapshot: IndexInsightsSnapshot) {
        let initial = snapshot.usage.initialSearches
        let refined = snapshot.usage.refinedSearches
        queryRouteView.setCounters(preview: initial, final: refined)
        replaceQueryRouteGroups(initial: initial, refined: refined)
    }

    private func replaceQueryRouteGroups(initial: SearchUsageCounters, refined: SearchUsageCounters) {
        replaceRows(in: queryRouteGroupsStack, with: [
            makeRouteMatrixHeaderRow(),
            makeRouteMatrixPhaseGroup(
                title: "Preview",
                counters: previewDisplayCounters(initial),
                accessibilityIdentifier: "Insights.PreviewRouteGroup"
            ),
            makeRouteMatrixPhaseGroup(
                title: "Final",
                counters: refined,
                accessibilityIdentifier: "Insights.FinalRouteGroup"
            )
        ])
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

    private func rebuildStorageFacts(
        _ snapshot: IndexInsightsSnapshot,
        displayedRoots: [IndexRootInsight],
        accessStatuses: [String: InsightsRootAccessStatus],
        activePlaceholder: String?
    ) {
        let rootsWithData = displayedRoots.filter { root in
            root.trackedFileCount > 0 || root.directoryCount > 0 || root.pathByteWeight > 0
        }.count
        let rootValue = displayedRoots.isEmpty
            ? "none"
            : "\(rootsWithData.formatted()) / \(displayedRoots.count.formatted()) active"
        let storageDetails = storageSummaryText(
            snapshot,
            displayedRoots: displayedRoots,
            accessStatuses: accessStatuses,
            activePlaceholder: activePlaceholder
        )
        replaceFacts(in: storageFactsStack, with: [
            InsightsFact("ATT Data", byteString(snapshot.storage.totalATTDataBytes)),
            InsightsFact("Index Package", byteString(snapshot.storage.indexPackageBytes)),
            InsightsFact("Cache", byteString(snapshot.storage.cacheBytes)),
            InsightsFact("Measurement", storageMeasurementValue(snapshot.storage), tooltip: storageMeasurementText(snapshot.storage)),
            InsightsFact("Roots", rootValue, tooltip: storageDetails)
        ])
    }

    private func rebuildActivityFacts(_ snapshot: IndexInsightsSnapshot) {
        let searches = snapshot.usage.allTimeSearches
        let health = snapshot.usage.health
        replaceFacts(in: activityFactsStack, with: [
            InsightsFact("Completed", searches.completed.formatted()),
            InsightsFact("Fallbacks", searches.fallbackScans.formatted()),
            InsightsFact("Avg Latency", durationString(searches.averageLatency)),
            InsightsFact("Max Latency", durationString(searches.maxLatency)),
            InsightsFact("File Actions", totalFileActionString(snapshot.usage.allTimeFileActions)),
            InsightsFact("Index Updates", health.incrementalRefreshBatches.formatted()),
            InsightsFact("Full Rebuilds", health.fullRebuilds.formatted()),
            InsightsFact("Last Refresh", optionalDurationString(health.lastRefreshDuration))
        ])
    }

    private func rebuildLifetimeFacts(_ snapshot: IndexInsightsSnapshot) {
        replaceFacts(in: lifetimeFactsStack, with: [
            InsightsFact("First Launch", dateOnlyString(snapshot.lifetime.firstLaunchDate)),
            InsightsFact("Launches", snapshot.lifetime.launchCount.formatted()),
            InsightsFact("Version Seen", dateOnlyString(snapshot.lifetime.currentAppVersionFirstSeenDate)),
            InsightsFact("Memory Today", memoryTodayString(snapshot.usage.dailyBuckets.last?.memory))
        ])
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
            return "Index package by root"
        }
        return "Index package by root (\(rootsWithData)/\(roots.count) active)"
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

    private func makePage(accessibilityIdentifier: String) -> NSView {
        let page = NSView()
        page.translatesAutoresizingMaskIntoConstraints = false
        page.setAccessibilityIdentifier(accessibilityIdentifier)
        return page
    }

    private func makePanelTitleLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        allowHorizontalCompression(label)
        return label
    }

    private func configureFactsStack(_ stack: NSStackView) {
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
    }

    private func configureRowsStack(_ stack: NSStackView) {
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
    }

    private func replaceRows(in stack: NSStackView, with rows: [NSView]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, row) in rows.enumerated() {
            stack.addArrangedSubview(row)
            if index < rows.count - 1 {
                stack.addArrangedSubview(makeTableSeparator())
            }
        }
    }

    private func replaceFacts(in stack: NSStackView, with facts: [InsightsFact]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, fact) in facts.enumerated() {
            stack.addArrangedSubview(makeFactRow(fact))
            if index < facts.count - 1 {
                stack.addArrangedSubview(makeTableSeparator())
            }
        }
    }

    private func makeDivider() -> NSView {
        let view = InsightsTableSeparatorView()
        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: 2)
        ])
        return view
    }

    private func makeTableSeparator() -> NSView {
        let view = InsightsTableSeparatorView()
        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: 2)
        ])
        return view
    }

    private func makeFactTable(containing content: NSView, accessibilityIdentifier: String) -> NSView {
        let table = InsightsFactTableView()
        table.setAccessibilityIdentifier(accessibilityIdentifier)
        content.translatesAutoresizingMaskIntoConstraints = false
        table.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: table.topAnchor),
            content.leadingAnchor.constraint(equalTo: table.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: table.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: table.bottomAnchor)
        ])
        return table
    }

    private func makeFactRow(_ fact: InsightsFact) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.toolTip = fact.tooltip

        let titleLabel = NSTextField(labelWithString: fact.title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.toolTip = fact.tooltip

        let valueLabel = NSTextField(labelWithString: fact.value)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        valueLabel.textColor = .labelColor
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.toolTip = fact.tooltip
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        row.addSubview(titleLabel)
        row.addSubview(valueLabel)
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 26),
            titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
            valueLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            valueLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private enum RouteMatrixLayout {
        static let tableWidth: CGFloat = 620
        static let phaseWidth: CGFloat = 76
        static let metricWidth: CGFloat = 54
        static let routeCountWidth: CGFloat = 50
        static let doneWidth: CGFloat = 54
        static let cancelWidth: CGFloat = 60
        static let averageWidth: CGFloat = 72
        static let spacing: CGFloat = 6
    }

    private func makeRouteMatrixHeaderRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setAccessibilityIdentifier("Insights.RouteMatrixHeader")

        let phaseLabel = makeRouteMatrixHeaderCell("Phase", alignment: .left)
        let labels = [
            makeRouteMatrixHeaderCell("Metric", alignment: .left),
            makeRouteMatrixRouteHeaderCell("Side", route: .sidecar),
            makeRouteMatrixRouteHeaderCell("Map", route: .mappedIndex),
            makeRouteMatrixRouteHeaderCell("Scan", route: .fullScan),
            makeRouteMatrixRouteHeaderCell("App", route: .applicationCatalog),
            makeRouteMatrixRouteHeaderCell("Other", route: .other),
            makeRouteMatrixHeaderCell("Done"),
            makeRouteMatrixHeaderCell("Cancel"),
            makeRouteMatrixHeaderCell("Avg")
        ]
        let grid = makeRouteMetricGrid(labels)
        row.addSubview(phaseLabel)
        row.addSubview(grid)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 26),
            phaseLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            phaseLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            phaseLabel.widthAnchor.constraint(equalToConstant: RouteMatrixLayout.phaseWidth),

            grid.topAnchor.constraint(equalTo: row.topAnchor, constant: 5),
            grid.leadingAnchor.constraint(equalTo: phaseLabel.trailingAnchor, constant: RouteMatrixLayout.spacing),
            grid.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            grid.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -3)
        ])
        return row
    }

    private func makeRouteMatrixPhaseGroup(
        title: String,
        counters: SearchUsageCounters,
        accessibilityIdentifier: String
    ) -> NSView {
        let group = NSView()
        group.translatesAutoresizingMaskIntoConstraints = false
        group.setAccessibilityIdentifier(accessibilityIdentifier)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        allowHorizontalCompression(titleLabel)

        let countGrid = makeRouteMetricGrid([
            makeRouteMetricLabelCell("Count"),
            makeRouteMatrixValueCell(routeCountString(counters, .sidecar)),
            makeRouteMatrixValueCell(routeCountString(counters, .mappedIndex)),
            makeRouteMatrixValueCell(routeCountString(counters, .fullScan)),
            makeRouteMatrixValueCell(routeCountString(counters, .applicationCatalog)),
            makeRouteMatrixValueCell(routeCountString(counters, .other)),
            makeRouteMatrixValueCell(counters.completed.formatted()),
            makeRouteMatrixValueCell(counters.cancelled.formatted()),
            makeRouteMatrixValueCell("")
        ])
        let averageGrid = makeRouteMetricGrid([
            makeRouteMetricLabelCell("Avg", isSecondary: true),
            makeRouteMatrixValueCell(routeAverageString(counters, .sidecar), isSecondary: true),
            makeRouteMatrixValueCell(routeAverageString(counters, .mappedIndex), isSecondary: true),
            makeRouteMatrixValueCell(routeAverageString(counters, .fullScan), isSecondary: true),
            makeRouteMatrixValueCell(routeAverageString(counters, .applicationCatalog), isSecondary: true),
            makeRouteMatrixValueCell(routeAverageString(counters, .other), isSecondary: true),
            makeRouteMatrixValueCell("", isSecondary: true),
            makeRouteMatrixValueCell("", isSecondary: true),
            makeRouteMatrixValueCell(durationString(counters.averageLatency), isSecondary: true)
        ])
        let separator = makeTableSeparator()

        group.addSubview(titleLabel)
        group.addSubview(countGrid)
        group.addSubview(separator)
        group.addSubview(averageGrid)
        NSLayoutConstraint.activate([
            group.heightAnchor.constraint(equalToConstant: 54),

            titleLabel.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: group.centerYAnchor),
            titleLabel.widthAnchor.constraint(equalToConstant: RouteMatrixLayout.phaseWidth),

            countGrid.topAnchor.constraint(equalTo: group.topAnchor, constant: 4),
            countGrid.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: RouteMatrixLayout.spacing),
            countGrid.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -12),
            countGrid.heightAnchor.constraint(equalToConstant: 21),

            separator.leadingAnchor.constraint(equalTo: countGrid.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: countGrid.trailingAnchor),
            separator.topAnchor.constraint(equalTo: countGrid.bottomAnchor),

            averageGrid.topAnchor.constraint(equalTo: separator.bottomAnchor),
            averageGrid.leadingAnchor.constraint(equalTo: countGrid.leadingAnchor),
            averageGrid.trailingAnchor.constraint(equalTo: countGrid.trailingAnchor),
            averageGrid.bottomAnchor.constraint(equalTo: group.bottomAnchor, constant: -4)
        ])
        return group
    }

    private func previewDisplayCounters(_ counters: SearchUsageCounters) -> SearchUsageCounters {
        InsightsRoutePresentation.previewDisplayCounters(counters)
    }

    private func routeCountString(_ counters: SearchUsageCounters, _ route: SearchRouteKind) -> String {
        guard let count = counters.routeCounts[route], count > 0 else { return "" }
        return count.formatted()
    }

    private func routeAverageString(_ counters: SearchUsageCounters, _ route: SearchRouteKind) -> String {
        guard counters.hasAverageLatency(for: route) else { return "" }
        return durationString(counters.averageLatency(for: route))
    }

    private func makeRouteMetricGrid(_ cells: [NSView]) -> NSStackView {
        let grid = NSStackView(views: cells)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.orientation = .horizontal
        grid.alignment = .centerY
        grid.distribution = .fill
        grid.spacing = RouteMatrixLayout.spacing

        for (index, cell) in cells.enumerated() {
            if index == 0 {
                cell.widthAnchor.constraint(equalToConstant: RouteMatrixLayout.metricWidth).isActive = true
            } else if index == cells.count - 1 {
                cell.widthAnchor.constraint(equalToConstant: RouteMatrixLayout.averageWidth).isActive = true
            } else if index == cells.count - 2 {
                cell.widthAnchor.constraint(equalToConstant: RouteMatrixLayout.cancelWidth).isActive = true
            } else if index == cells.count - 3 {
                cell.widthAnchor.constraint(equalToConstant: RouteMatrixLayout.doneWidth).isActive = true
            } else {
                cell.widthAnchor.constraint(equalToConstant: RouteMatrixLayout.routeCountWidth).isActive = true
            }
        }
        return grid
    }

    private func makeRouteMatrixHeaderCell(_ title: String, alignment: NSTextAlignment = .right) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 9.5, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        allowHorizontalCompression(label)
        return label
    }

    private func makeRouteMatrixRouteHeaderCell(_ title: String, route: SearchRouteKind) -> NSView {
        let cell = NSView()
        cell.translatesAutoresizingMaskIntoConstraints = false

        let marker = NSView()
        marker.translatesAutoresizingMaskIntoConstraints = false
        marker.wantsLayer = true
        marker.layer?.cornerRadius = 2
        marker.layer?.backgroundColor = AppTheme.resolvedCGColor(InsightsRouteMixView.color(for: route), for: view)

        let label = makeRouteMatrixHeaderCell(title, alignment: .left)
        let cluster = NSStackView(views: [marker, label])
        cluster.translatesAutoresizingMaskIntoConstraints = false
        cluster.orientation = .horizontal
        cluster.alignment = .centerY
        cluster.distribution = .fill
        cluster.spacing = 4

        cell.addSubview(cluster)
        NSLayoutConstraint.activate([
            marker.widthAnchor.constraint(equalToConstant: 6),
            marker.heightAnchor.constraint(equalToConstant: 6),

            cluster.leadingAnchor.constraint(greaterThanOrEqualTo: cell.leadingAnchor),
            cluster.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            cluster.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func makeRouteMetricLabelCell(_ value: String, isSecondary: Bool = false) -> NSTextField {
        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.font = .systemFont(ofSize: 10.5, weight: isSecondary ? .medium : .semibold)
        valueLabel.textColor = isSecondary ? .secondaryLabelColor : .labelColor
        valueLabel.alignment = .left
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.maximumNumberOfLines = 1
        allowHorizontalCompression(valueLabel)
        return valueLabel
    }

    private func makeRouteMatrixValueCell(_ value: String, isSecondary: Bool = false) -> NSTextField {
        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: isSecondary ? .medium : .semibold)
        valueLabel.textColor = value.isEmpty ? .clear : (isSecondary ? .secondaryLabelColor : .labelColor)
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.maximumNumberOfLines = 1
        allowHorizontalCompression(valueLabel)
        return valueLabel
    }

    private func makeMetricTile(title: String, value: String, detail: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .left
        allowHorizontalCompression(titleLabel)

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        valueLabel.textColor = .labelColor
        valueLabel.alignment = .left
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.maximumNumberOfLines = 1
        allowHorizontalCompression(valueLabel)

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .left
        detailLabel.lineBreakMode = .byTruncatingTail
        allowHorizontalCompression(detailLabel)

        let stack = InsightsTileView(views: [titleLabel, valueLabel, detailLabel], style: .metric)
        stack.spacing = 2
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 9, bottom: 5, right: 9)
        NSLayoutConstraint.activate([
            stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 58)
        ])
        return stack
    }

    private func makeHealthTile(title: String, value: String, detail: String, isWarning: Bool = false) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        allowHorizontalCompression(titleLabel)

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        valueLabel.textColor = isWarning ? .systemOrange : .labelColor
        valueLabel.alignment = .left
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.maximumNumberOfLines = 1
        allowHorizontalCompression(valueLabel)

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .left
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        allowHorizontalCompression(detailLabel)

        let stack = InsightsTileView(views: [titleLabel, valueLabel, detailLabel], style: .health)
        stack.spacing = 4
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        NSLayoutConstraint.activate([
            stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 74)
        ])
        return stack
    }

    private func makeCard(containing content: NSView) -> NSView {
        let card = InsightsCardView()

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

    private func makeOutlinedPanel(containing content: NSView) -> NSView {
        let panel = InsightsOutlinePanelView()

        content.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10)
        ])
        return panel
    }

    private func compactRouteSummary(_ counters: SearchUsageCounters) -> String {
        InsightsQueryRouteSummary.compactRouteSummary(counters)
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

    private func storageMeasurementValue(_ storage: IndexStorageInsights) -> String {
        if storage.isMeasuring {
            return "measuring"
        }
        guard let measuredAt = storage.measuredAt else {
            return "pending"
        }
        return relativeDateString(measuredAt)
    }

    private func optionalDurationString(_ duration: TimeInterval?) -> String {
        guard let duration else { return "none" }
        return durationString(duration)
    }

    private func totalFileActionString(_ actions: [FileActionMetric: UInt64]) -> String {
        actions.values.reduce(UInt64(0), +).formatted()
    }

    private func memoryTodayString(_ memory: MemoryUsageCounters?) -> String {
        guard let memory else { return "no samples" }
        return "\(byteString(memory.dailyMinimumBytes)) - \(byteString(memory.dailyMaximumBytes))"
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
        if stats.activityPresentation == .backgroundCatchUp {
            return "Catching up"
        }

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

enum InsightsQueryRouteSummary {
    static func routeCountString(_ counters: SearchUsageCounters, _ route: SearchRouteKind) -> String {
        counters.routeCounts[route, default: 0].formatted()
    }

    static func applicationOtherRouteString(_ counters: SearchUsageCounters) -> String {
        let application = counters.routeCounts[.applicationCatalog, default: 0]
        let other = counters.routeCounts[.other, default: 0]
        guard other > 0 else { return application.formatted() }
        return "\(application.formatted()) / \(other.formatted())"
    }

    static func compactRouteSummary(_ counters: SearchUsageCounters) -> String {
        let sidecars = counters.routeCounts[.sidecar, default: 0]
        let fullScans = counters.routeCounts[.fullScan, default: 0]
        let mapped = counters.routeCounts[.mappedIndex, default: 0]
        let application = counters.routeCounts[.applicationCatalog, default: 0]
        let other = counters.routeCounts[.other, default: 0]
        if counters.completed == 0 {
            return "none"
        }
        return "side \(sidecars.formatted()) · map \(mapped.formatted()) · scan \(fullScans.formatted()) · app \(application.formatted()) · other \(other.formatted())"
    }

    static func percentString(numerator: UInt64, denominator: UInt64) -> String {
        guard denominator > 0 else { return "0%" }
        let percent = Double(numerator) / Double(denominator) * 100
        if percent > 0, percent < 1 {
            return "<1%"
        }
        return "\(Int(percent.rounded()))%"
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

enum InsightsPanelPalette {
    static func isDarkAppearance(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func cardBackgroundColor(isDark: Bool) -> NSColor {
        isDark
            ? NSColor(calibratedWhite: 0.14, alpha: 0.72)
            : NSColor(calibratedWhite: 0.98, alpha: 0.90)
    }

    static func cardBorderColor(isDark: Bool) -> NSColor {
        isDark
            ? NSColor(calibratedWhite: 0.62, alpha: 0.42)
            : NSColor(calibratedWhite: 0.54, alpha: 0.34)
    }

    static func tableRuleColor(isDark: Bool) -> NSColor {
        isDark
            ? NSColor(calibratedWhite: 0.78, alpha: 0.50)
            : NSColor(calibratedWhite: 0.36, alpha: 0.44)
    }

    static func tileBackgroundColor(style: InsightsPanelTileStyle, isDark: Bool) -> NSColor {
        switch (style, isDark) {
        case (.metric, true):
            NSColor(calibratedWhite: 0.10, alpha: 0.56)
        case (.health, true):
            NSColor(calibratedWhite: 0.10, alpha: 0.44)
        case (.metric, false):
            NSColor(calibratedWhite: 0.92, alpha: 0.96)
        case (.health, false):
            NSColor(calibratedWhite: 0.93, alpha: 0.92)
        }
    }

    static func chartBackgroundColor(isDark: Bool) -> NSColor {
        isDark
            ? NSColor(calibratedWhite: 0.10, alpha: 1)
            : NSColor(calibratedWhite: 1, alpha: 1)
    }

    static func treemapStrokeColor(isDark: Bool) -> NSColor {
        isDark
            ? NSColor.white.withAlphaComponent(0.22)
            : NSColor.black.withAlphaComponent(0.10)
    }
}

enum InsightsPanelTileStyle {
    case metric
    case health
}

private final class InsightsCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 0
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateThemeColors()
    }

    private func updateThemeColors() {
        let isDark = InsightsPanelPalette.isDarkAppearance(effectiveAppearance)
        layer?.backgroundColor = AppTheme.resolvedCGColor(
            InsightsPanelPalette.cardBackgroundColor(isDark: isDark),
            for: self
        )
        layer?.borderColor = AppTheme.resolvedCGColor(
            InsightsPanelPalette.cardBorderColor(isDark: isDark),
            for: self
        )
    }
}

private final class InsightsOutlinePanelView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1.5
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateThemeColors()
    }

    private func updateThemeColors() {
        let isDark = InsightsPanelPalette.isDarkAppearance(effectiveAppearance)
        layer?.backgroundColor = AppTheme.resolvedCGColor(
            InsightsPanelPalette.cardBackgroundColor(isDark: isDark),
            for: self
        )
        layer?.borderColor = AppTheme.resolvedCGColor(
            InsightsPanelPalette.cardBorderColor(isDark: isDark),
            for: self
        )
    }
}

private final class InsightsFactTableView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1.5
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateThemeColors()
    }

    private func updateThemeColors() {
        let isDark = InsightsPanelPalette.isDarkAppearance(effectiveAppearance)
        layer?.backgroundColor = AppTheme.resolvedCGColor(
            InsightsPanelPalette.cardBackgroundColor(isDark: isDark).withAlphaComponent(isDark ? 0.30 : 0.58),
            for: self
        )
        layer?.borderColor = AppTheme.resolvedCGColor(
            InsightsPanelPalette.cardBorderColor(isDark: isDark),
            for: self
        )
    }
}

private final class InsightsTableSeparatorView: NSView {
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateThemeColors()
    }

    private func updateThemeColors() {
        let isDark = InsightsPanelPalette.isDarkAppearance(effectiveAppearance)
        layer?.backgroundColor = AppTheme.resolvedCGColor(
            InsightsPanelPalette.tableRuleColor(isDark: isDark),
            for: self
        )
    }
}

private final class InsightsTileView: NSStackView {
    private let style: InsightsPanelTileStyle

    init(views: [NSView], style: InsightsPanelTileStyle) {
        self.style = style
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        orientation = .vertical
        alignment = .width
        for view in views {
            addArrangedSubview(view)
        }
        wantsLayer = true
        layer?.cornerRadius = 6
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateThemeColors()
    }

    private func updateThemeColors() {
        let isDark = InsightsPanelPalette.isDarkAppearance(effectiveAppearance)
        layer?.backgroundColor = AppTheme.resolvedCGColor(
            InsightsPanelPalette.tileBackgroundColor(style: style, isDark: isDark),
            for: self
        )
    }
}

enum InsightsHoverCardLayout {
    static let lineHeight: CGFloat = 16

    static var titleAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
    }

    static var detailAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
    }

    static func placardRect(lines: [String], near point: NSPoint, in bounds: NSRect) -> NSRect {
        guard !lines.isEmpty, bounds.width > 0, bounds.height > 0 else { return .zero }
        let measured = lines.enumerated().map { index, line in
            line.size(withAttributes: index == 0 ? Self.titleAttributes : Self.detailAttributes)
        }
        let maximumWidth = max(120, bounds.width - 20)
        let width = min(max(measured.map(\.width).max() ?? 0, 160) + 20, maximumWidth)
        let height = CGFloat(lines.count) * Self.lineHeight + 18
        var origin = NSPoint(x: point.x + 12, y: point.y + 12)
        if origin.x + width > bounds.maxX - 8 {
            origin.x = point.x - width - 12
        }
        if origin.y + height > bounds.maxY - 8 {
            origin.y = point.y - height - 12
        }
        origin.x = min(max(origin.x, bounds.minX + 8), max(bounds.minX + 8, bounds.maxX - width - 8))
        origin.y = min(max(origin.y, bounds.minY + 8), max(bounds.minY + 8, bounds.maxY - height - 8))
        return NSRect(origin: origin, size: NSSize(width: width, height: height))
    }
}

private final class InsightsHoverCardView: NSView {
    private var lines: [String] = []
    private var anchorPoint: NSPoint = .zero

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func show(lines: [String], near point: NSPoint) {
        self.lines = lines
        anchorPoint = point
        isHidden = false
        needsDisplay = true
    }

    func hide() {
        lines = []
        isHidden = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !lines.isEmpty else { return }

        let rect = InsightsHoverCardLayout.placardRect(lines: lines, near: anchorPoint, in: bounds)
        guard !rect.isEmpty else { return }
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        NSColor.separatorColor.withAlphaComponent(0.85).setStroke()
        NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7).stroke()

        var y = rect.minY + 9
        for (index, line) in lines.enumerated() {
            let attributes = index == 0
                ? InsightsHoverCardLayout.titleAttributes
                : InsightsHoverCardLayout.detailAttributes
            line.draw(
                in: NSRect(x: rect.minX + 10, y: y, width: rect.width - 20, height: InsightsHoverCardLayout.lineHeight),
                withAttributes: attributes
            )
            y += InsightsHoverCardLayout.lineHeight
        }
    }
}

private enum InsightsHoverCard {
    @MainActor
    static func show(lines: [String], near point: NSPoint, from sourceView: NSView) {
        guard !lines.isEmpty, let contentView = sourceView.window?.contentView else { return }
        let cardView = hoverCardView(in: contentView)
        if cardView.superview == nil {
            contentView.addSubview(cardView, positioned: .above, relativeTo: nil)
        }
        cardView.frame = contentView.bounds
        cardView.autoresizingMask = [.width, .height]
        cardView.show(lines: lines, near: cardView.convert(point, from: sourceView))
    }

    @MainActor
    static func hide(from sourceView: NSView) {
        guard let contentView = sourceView.window?.contentView else { return }
        contentView.subviews
            .compactMap { $0 as? InsightsHoverCardView }
            .first?
            .hide()
    }

    @MainActor
    private static func hoverCardView(in contentView: NSView) -> InsightsHoverCardView {
        if let existing = contentView.subviews.compactMap({ $0 as? InsightsHoverCardView }).first {
            return existing
        }
        let view = InsightsHoverCardView(frame: contentView.bounds)
        view.autoresizingMask = [.width, .height]
        view.isHidden = true
        return view
    }
}

private final class InsightsRouteMixView: NSView {
    private var previewCounters = SearchUsageCounters()
    private var finalCounters = SearchUsageCounters()

    override var isFlipped: Bool { true }

    private var trackingArea: NSTrackingArea?
    private var hoveredTarget: InsightsRouteMixHoverTarget?
    private var hoverPoint: NSPoint?

    func setCounters(preview: SearchUsageCounters, final: SearchUsageCounters) {
        previewCounters = InsightsRoutePresentation.previewDisplayCounters(preview)
        finalCounters = final
        refreshHoverAfterContentUpdate()
        needsDisplay = true
    }

    static func color(for route: SearchRouteKind) -> NSColor {
        switch route {
        case .sidecar:
            return .systemGreen
        case .fullScan:
            return .systemOrange
        case .mappedIndex:
            return .systemPurple
        case .applicationCatalog:
            return .systemBlue
        case .other:
            return .systemGray
        }
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHover(at: point)
        updateHoverCard()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredTarget = nil
        hoverPoint = nil
        InsightsHoverCard.hide(from: self)
        needsDisplay = true
    }

    private func refreshHoverAfterContentUpdate() {
        guard
            let hoverPoint,
            bounds.contains(hoverPoint),
            window?.isKeyWindow != false
        else {
            hoveredTarget = nil
            self.hoverPoint = nil
            InsightsHoverCard.hide(from: self)
            return
        }

        updateHover(at: hoverPoint)
        updateHoverCard()
    }

    private func updateHover(at point: NSPoint) {
        hoverPoint = point
        hoveredTarget = InsightsRouteMixLayout.hitTarget(
            at: point,
            preview: previewCounters,
            final: finalCounters,
            in: bounds.insetBy(dx: 0.5, dy: 0.5)
        )
    }

    private func updateHoverCard() {
        guard let hoveredTarget, let hoverPoint else {
            InsightsHoverCard.hide(from: self)
            return
        }

        let segments = InsightsRouteMixLayout.segments(
            preview: previewCounters,
            final: finalCounters,
            in: bounds.insetBy(dx: 0.5, dy: 0.5)
        )
        let phaseSegments = segments.filter { $0.phase == hoveredTarget.phase }
        let total = segments.reduce(UInt64(0)) { $0 &+ $1.count }
        let phaseTotal = phaseSegments.reduce(UInt64(0)) { $0 &+ $1.count }
        guard let segment = phaseSegments.first(where: { $0.route == hoveredTarget.route }) else {
            InsightsHoverCard.hide(from: self)
            return
        }

        InsightsHoverCard.show(
            lines: routeHoverLines(
                target: hoveredTarget,
                count: segment.count,
                phaseTotal: phaseTotal,
                total: total
            ),
            near: hoverPoint,
            from: self
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let isDark = InsightsPanelPalette.isDarkAppearance(effectiveAppearance)
        let background = InsightsPanelPalette.chartBackgroundColor(isDark: isDark)
        let border = InsightsPanelPalette.treemapStrokeColor(isDark: isDark)
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        background.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()

        let rows = InsightsRouteMixLayout.barRows(in: rect)
        let segments = InsightsRouteMixLayout.segments(
            preview: previewCounters,
            final: finalCounters,
            in: rect
        )
        guard !segments.isEmpty else {
            drawEmpty("No route data")
            border.setStroke()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).stroke()
            return
        }

        for row in rows {
            drawPhaseLabel(row.phase.rawValue, in: row.labelRect)
        }

        for segment in segments {
            let isHovered = hoveredTarget?.phase == segment.phase && hoveredTarget?.route == segment.route
            let alpha: CGFloat = hoveredTarget == nil || isHovered ? 0.82 : 0.54
            Self.color(for: segment.route).withAlphaComponent(alpha).setFill()
            segment.rect.fill()
            if isHovered {
                NSColor.white.withAlphaComponent(0.55).setStroke()
                NSBezierPath(roundedRect: segment.rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).stroke()
            }
            if segment.rect.width > 56 {
                drawCount(segment.count, in: segment.rect)
            }
        }

        border.setStroke()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).stroke()
    }

    private func routeHoverLines(
        target: InsightsRouteMixHoverTarget,
        count: UInt64,
        phaseTotal: UInt64,
        total: UInt64
    ) -> [String] {
        let phasePercent = InsightsRouteMixLayout.percentString(count: count, total: phaseTotal)
        let totalPercent = InsightsRouteMixLayout.percentString(count: count, total: total)
        return [
            "\(target.phase.rawValue) \(InsightsRouteMixLayout.title(for: target.route))",
            "\(count.formatted()) searches",
            "\(phasePercent) of \(target.phase.rawValue.lowercased())",
            "\(totalPercent) of routed queries"
        ]
    }

    private func drawEmpty(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private func drawPhaseLabel(_ text: String, in rect: NSRect) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            in: NSRect(
                x: rect.minX,
                y: rect.midY - size.height / 2,
                width: rect.width,
                height: size.height
            ),
            withAttributes: attributes
        )
    }

    private func drawCount(_ count: UInt64, in rect: NSRect) {
        let text = count.formatted()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}

enum InsightsRouteMixPhase: String, CaseIterable {
    case preview = "Preview"
    case final = "Final"
}

struct InsightsRouteMixHoverTarget: Equatable {
    let phase: InsightsRouteMixPhase
    let route: SearchRouteKind
}

struct InsightsRouteMixBarRow: Equatable {
    let phase: InsightsRouteMixPhase
    let labelRect: NSRect
    let barRect: NSRect
}

struct InsightsRouteMixSegment: Equatable {
    let phase: InsightsRouteMixPhase
    let route: SearchRouteKind
    let count: UInt64
    let rect: NSRect
}

enum InsightsRouteMixLayout {
    static let routes: [SearchRouteKind] = [.sidecar, .mappedIndex, .fullScan, .applicationCatalog, .other]
    private static let labelWidth: CGFloat = 54
    private static let labelGap: CGFloat = 8
    private static let rowGap: CGFloat = 6
    private static let horizontalInset: CGFloat = 8
    private static let verticalInset: CGFloat = 7

    static func barRows(in rect: NSRect) -> [InsightsRouteMixBarRow] {
        let content = rect.insetBy(dx: horizontalInset, dy: verticalInset)
        guard content.width > labelWidth + labelGap, content.height > rowGap else { return [] }

        let rowHeight = max(4, floor((content.height - rowGap) / 2))
        let barX = content.minX + labelWidth + labelGap
        let barWidth = content.maxX - barX
        guard barWidth > 0 else { return [] }

        return [
            InsightsRouteMixBarRow(
                phase: .preview,
                labelRect: NSRect(x: content.minX, y: content.minY, width: labelWidth, height: rowHeight),
                barRect: NSRect(x: barX, y: content.minY, width: barWidth, height: rowHeight)
            ),
            InsightsRouteMixBarRow(
                phase: .final,
                labelRect: NSRect(
                    x: content.minX,
                    y: content.minY + rowHeight + rowGap,
                    width: labelWidth,
                    height: rowHeight
                ),
                barRect: NSRect(
                    x: barX,
                    y: content.minY + rowHeight + rowGap,
                    width: barWidth,
                    height: rowHeight
                )
            )
        ]
    }

    static func segments(
        preview: SearchUsageCounters,
        final: SearchUsageCounters,
        in rect: NSRect
    ) -> [InsightsRouteMixSegment] {
        let preview = InsightsRoutePresentation.previewDisplayCounters(preview)
        let countersByPhase: [InsightsRouteMixPhase: SearchUsageCounters] = [
            .preview: preview,
            .final: final
        ]
        return barRows(in: rect).flatMap { row in
            segments(
                phase: row.phase,
                counters: countersByPhase[row.phase] ?? SearchUsageCounters(),
                in: row.barRect
            )
        }
    }

    private static func segments(
        phase: InsightsRouteMixPhase,
        counters: SearchUsageCounters,
        in rect: NSRect
    ) -> [InsightsRouteMixSegment] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        let counts = routes.map { counters.routeCounts[$0, default: 0] }
        let total = counts.reduce(UInt64(0), +)
        guard total > 0 else { return [] }

        var x = rect.minX
        let lastPositiveIndex = counts.indices.last { counts[$0] > 0 }
        var segments: [InsightsRouteMixSegment] = []
        segments.reserveCapacity(routes.count)

        for (index, route) in routes.enumerated() {
            let count = counts[index]
            guard count > 0 else { continue }
            let isLast = index == lastPositiveIndex
            let width = isLast
                ? rect.maxX - x
                : max(2, floor(rect.width * CGFloat(Double(count) / Double(total))))
            let segmentRect = NSRect(
                x: x,
                y: rect.minY,
                width: min(width, rect.maxX - x),
                height: rect.height
            )
            guard segmentRect.width > 0 else { continue }
            segments.append(InsightsRouteMixSegment(phase: phase, route: route, count: count, rect: segmentRect))
            x += segmentRect.width
        }

        return segments
    }

    static func hitTarget(
        at point: NSPoint,
        preview: SearchUsageCounters,
        final: SearchUsageCounters,
        in rect: NSRect
    ) -> InsightsRouteMixHoverTarget? {
        guard let segment = segments(preview: preview, final: final, in: rect).first(where: { $0.rect.contains(point) }) else {
            return nil
        }
        return InsightsRouteMixHoverTarget(phase: segment.phase, route: segment.route)
    }

    static func title(for route: SearchRouteKind) -> String {
        switch route {
        case .sidecar:
            return "Sidecar"
        case .mappedIndex:
            return "Mapped index"
        case .fullScan:
            return "Full scan"
        case .applicationCatalog:
            return "App catalog"
        case .other:
            return "Other"
        }
    }

    static func percentString(count: UInt64, total: UInt64) -> String {
        guard total > 0 else { return "0%" }
        let percent = Double(count) / Double(total) * 100
        if percent > 0, percent < 0.1 {
            return "<0.1%"
        }
        if percent < 10 {
            return String(format: "%.1f%%", percent)
        }
        return "\(Int(percent.rounded()))%"
    }
}

private final class InsightsTreemapView: NSView {
    var roots: [IndexRootInsight] = [] {
        didSet {
            refreshHoverAfterContentUpdate()
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    private var trackingArea: NSTrackingArea?
    private var hoveredRootIndex: Int?
    private var hoverPoint: NSPoint?
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHover(at: point)
        updateHoverCard()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredRootIndex = nil
        hoverPoint = nil
        InsightsHoverCard.hide(from: self)
        needsDisplay = true
    }

    private func refreshHoverAfterContentUpdate() {
        guard
            let hoverPoint,
            bounds.contains(hoverPoint),
            window?.isKeyWindow != false
        else {
            hoveredRootIndex = nil
            self.hoverPoint = nil
            InsightsHoverCard.hide(from: self)
            return
        }

        updateHover(at: hoverPoint)
        updateHoverCard()
    }

    private func updateHover(at point: NSPoint) {
        hoverPoint = point
        hoveredRootIndex = Self.rootIndex(
            at: point,
            roots: roots,
            bounds: bounds
        )
    }

    private func updateHoverCard() {
        guard let hoveredRootIndex, let hoverPoint, hoveredRootIndex < roots.count else {
            InsightsHoverCard.hide(from: self)
            return
        }

        let weights = roots.map(Self.layoutWeight(for:))
        let total = weights.reduce(UInt64(0)) { $0 &+ $1 }
        let labels = Self.compactLabels(for: roots.map(\.path))
        InsightsHoverCard.show(
            lines: Self.placardLines(
                for: roots[hoveredRootIndex],
                label: labels[hoveredRootIndex],
                weight: weights[hoveredRootIndex],
                totalWeight: total
            ),
            near: hoverPoint,
            from: self
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let isDark = InsightsPanelPalette.isDarkAppearance(effectiveAppearance)
        InsightsPanelPalette.chartBackgroundColor(isDark: isDark).setFill()
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
                InsightsPanelPalette.treemapStrokeColor(isDark: isDark).setStroke()
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

    nonisolated private static func rootIndex(at point: NSPoint, roots: [IndexRootInsight], bounds: NSRect) -> Int? {
        guard !roots.isEmpty else { return nil }
        let weights = roots.map(Self.layoutWeight(for:))
        let items = InsightsTreemapLayout.layout(weights: weights, in: bounds.insetBy(dx: 1, dy: 1))
        return InsightsTreemapLayout.hitItemIndex(at: point, in: items)
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

    private static func placardLines(
        for root: IndexRootInsight,
        label: String,
        weight: UInt64,
        totalWeight: UInt64
    ) -> [String] {
        let percent = Self.percentString(weight: weight, total: totalWeight)
        return [
            label,
            "\(percent) of estimated index package",
            "\(root.trackedFileCount.formatted()) files",
            "\(Self.byteString(root.indexedContentBytes)) content",
            "\(Self.byteString(root.estimatedIndexBytes)) index estimate"
        ]
    }

    nonisolated private static func percentString(weight: UInt64, total: UInt64) -> String {
        guard total > 0 else { return "0%" }
        let percent = Double(weight) / Double(total) * 100
        if percent > 0, percent < 0.1 {
            return "<0.1%"
        }
        if percent < 10 {
            return String(format: "%.1f%%", percent)
        }
        return "\(Int(percent.rounded()))%"
    }

    private static func byteString(_ bytes: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: bytes))
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
    private static let minimumHitSpan: CGFloat = 8

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

    static func hitItemIndex(at point: NSPoint, in items: [InsightsTreemapLayoutItem]) -> Int? {
        if let directHit = bestHit(at: point, in: items, rect: \.rect) {
            return directHit
        }
        return bestHit(at: point, in: items) { hitRect(for: $0.rect) }
    }

    private static func bestHit(
        at point: NSPoint,
        in items: [InsightsTreemapLayoutItem],
        rect: (InsightsTreemapLayoutItem) -> NSRect
    ) -> Int? {
        items
            .filter { rect($0).contains(point) }
            .min { lhs, rhs in
                let lhsArea = lhs.rect.width * lhs.rect.height
                let rhsArea = rhs.rect.width * rhs.rect.height
                if lhsArea != rhsArea {
                    return lhsArea < rhsArea
                }
                return lhs.index > rhs.index
            }?
            .index
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

    private static func hitRect(for rect: NSRect) -> NSRect {
        var hitRect = rect
        if hitRect.width < minimumHitSpan {
            hitRect = hitRect.insetBy(dx: -(minimumHitSpan - hitRect.width) / 2, dy: 0)
        }
        if hitRect.height < minimumHitSpan {
            hitRect = hitRect.insetBy(dx: 0, dy: -(minimumHitSpan - hitRect.height) / 2)
        }
        return hitRect
    }
}

private final class InsightsBarChartView: NSView {
    var buckets: [DailyUsageBucket] = [] {
        didSet {
            refreshHoverAfterContentUpdate()
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    private var trackingArea: NSTrackingArea?
    private var hoveredBucketIndex: Int?
    private var hoverPoint: NSPoint?

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHover(at: point)
        updateHoverCard()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredBucketIndex = nil
        hoverPoint = nil
        InsightsHoverCard.hide(from: self)
        needsDisplay = true
    }

    private func refreshHoverAfterContentUpdate() {
        guard
            let hoverPoint,
            bounds.contains(hoverPoint),
            window?.isKeyWindow != false
        else {
            hoveredBucketIndex = nil
            self.hoverPoint = nil
            InsightsHoverCard.hide(from: self)
            return
        }

        updateHover(at: hoverPoint)
        updateHoverCard()
    }

    private func updateHover(at point: NSPoint) {
        hoverPoint = point
        hoveredBucketIndex = InsightsActivityChartLayout.bucketIndex(
            at: point,
            bucketCount: buckets.count,
            in: bounds
        )
    }

    private func updateHoverCard() {
        guard let hoveredBucketIndex, let hoverPoint, hoveredBucketIndex < buckets.count else {
            InsightsHoverCard.hide(from: self)
            return
        }

        InsightsHoverCard.show(
            lines: placardLines(for: buckets[hoveredBucketIndex]),
            near: hoverPoint,
            from: self
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let isDark = InsightsPanelPalette.isDarkAppearance(effectiveAppearance)
        InsightsPanelPalette.chartBackgroundColor(isDark: isDark).setFill()
        bounds.fill()

        guard !buckets.isEmpty else {
            drawEmpty("No activity yet")
            return
        }

        let values = buckets.map { max($0.searches.completed, $0.fileActions.values.reduce(UInt64(0), +), $0.health.incrementalRefreshBatches + $0.health.fullRebuilds) }
        let maxValue = max(values.max() ?? 0, 1)
        let plot = InsightsActivityChartLayout.plotRect(in: bounds)
        let bucketRects = InsightsActivityChartLayout.bucketRects(bucketCount: buckets.count, in: bounds)

        if let hoveredBucketIndex, hoveredBucketIndex < bucketRects.count {
            let highlightRect = bucketRects[hoveredBucketIndex].insetBy(dx: -1, dy: 0)
            NSColor.labelColor.withAlphaComponent(isDark ? 0.10 : 0.06).setFill()
            NSBezierPath(roundedRect: highlightRect, xRadius: 3, yRadius: 3).fill()
        }

        for (index, bucket) in buckets.enumerated() {
            let bucketRect = bucketRects[index]
            let searchHeight = CGFloat(Double(bucket.searches.completed) / Double(maxValue)) * plot.height
            let actionCount = bucket.fileActions.values.reduce(UInt64(0), +)
            let actionHeight = CGFloat(Double(actionCount) / Double(maxValue)) * plot.height
            let updateHeight = CGFloat(Double(bucket.health.incrementalRefreshBatches + bucket.health.fullRebuilds) / Double(maxValue)) * plot.height

            drawBar(x: bucketRect.minX, width: bucketRect.width, height: searchHeight, color: .systemBlue, plot: plot)
            drawBar(x: bucketRect.minX, width: bucketRect.width, height: actionHeight, color: .systemGreen.withAlphaComponent(0.75), plot: plot.insetBy(dx: bucketRect.width * 0.25, dy: 0))
            drawBar(x: bucketRect.minX, width: bucketRect.width, height: updateHeight, color: .systemOrange.withAlphaComponent(0.8), plot: plot.insetBy(dx: bucketRect.width * 0.42, dy: 0))
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

    private func placardLines(for bucket: DailyUsageBucket) -> [String] {
        let actionCount = bucket.fileActions.values.reduce(UInt64(0), +)
        let updateCount = bucket.health.incrementalRefreshBatches + bucket.health.fullRebuilds
        return [
            bucket.day,
            "\(bucket.searches.completed.formatted()) searches completed",
            "\(actionCount.formatted()) file actions",
            "\(updateCount.formatted()) index updates"
        ]
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
    static let bucketGap: CGFloat = 3
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

    static func bucketRects(bucketCount: Int, in bounds: NSRect) -> [NSRect] {
        guard bucketCount > 0 else { return [] }
        let plot = plotRect(in: bounds)
        guard plot.width > 0, plot.height > 0 else { return [] }
        let barWidth = max(
            3,
            (plot.width - CGFloat(max(bucketCount - 1, 0)) * bucketGap) / CGFloat(bucketCount)
        )
        return (0..<bucketCount).map { index in
            NSRect(
                x: plot.minX + CGFloat(index) * (barWidth + bucketGap),
                y: plot.minY,
                width: barWidth,
                height: plot.height
            )
        }
    }

    static func bucketIndex(at point: NSPoint, bucketCount: Int, in bounds: NSRect) -> Int? {
        bucketRects(bucketCount: bucketCount, in: bounds)
            .firstIndex { $0.contains(point) }
    }
}
