@testable import AllTheThings
import AppKit
import ATTCore
import Testing

@Suite("Insights treemap layout")
struct InsightsTreemapLayoutTests {
    @Test("allocates proportional slices from remaining weight")
    func allocatesProportionalSlicesFromRemainingWeight() {
        let items = InsightsTreemapLayout.layout(
            weights: [60, 20, 20],
            in: NSRect(x: 0, y: 0, width: 100, height: 50)
        )

        #expect(items.map(\.index) == [0, 1, 2])
        #expect(items.map { Int(($0.rect.width * $0.rect.height).rounded()) } == [3_000, 1_000, 1_000])
    }

    @Test("preserves source indexes after dropping zero weight roots")
    func preservesSourceIndexesAfterDroppingZeroWeightRoots() {
        let items = InsightsTreemapLayout.layout(
            weights: [0, 10, 0, 10],
            in: NSRect(x: 0, y: 0, width: 80, height: 40)
        )

        #expect(items.map(\.index) == [1, 3])
        #expect(items.map { Int($0.rect.width.rounded()) } == [40, 40])
    }

    @Test("covers bounds without giving all leftover space to the last root")
    func coversBoundsWithoutGivingAllLeftoverSpaceToLastRoot() {
        let items = InsightsTreemapLayout.layout(
            weights: [1, 1, 1],
            in: NSRect(x: 0, y: 0, width: 300, height: 100)
        )

        #expect(items.count == 3)
        #expect(items.map { Int($0.rect.width.rounded()) } == [100, 100, 100])
        #expect(items.last?.rect.maxX == 300)
    }

    @Test("keeps tiny positive roots visible when space allows")
    func keepsTinyPositiveRootsVisibleWhenSpaceAllows() {
        let items = InsightsTreemapLayout.layout(
            weights: [9_017, 959, 22, 2],
            in: NSRect(x: 0, y: 0, width: 100, height: 50)
        )

        #expect(items.count == 4)
        #expect(items.allSatisfy { $0.rect.width >= 1 })
        #expect(items.last?.rect.maxX == 100)
    }

    @Test("hit testing expands tiny treemap slices")
    func hitTestingExpandsTinyTreemapSlices() {
        let items = [
            InsightsTreemapLayoutItem(index: 0, rect: NSRect(x: 0, y: 0, width: 95, height: 50)),
            InsightsTreemapLayoutItem(index: 1, rect: NSRect(x: 95, y: 0, width: 1, height: 50)),
            InsightsTreemapLayoutItem(index: 2, rect: NSRect(x: 96, y: 0, width: 4, height: 50))
        ]

        #expect(InsightsTreemapLayout.hitItemIndex(at: NSPoint(x: 95.4, y: 20), in: items) == 1)
        #expect(InsightsTreemapLayout.hitItemIndex(at: NSPoint(x: 98, y: 20), in: items) == 2)
    }

    @Test("root display includes configured roots missing from the snapshot")
    func rootDisplayIncludesConfiguredRootsMissingFromSnapshot() {
        let snapshotRoot = makeRoot(path: "/Users/example/Documents", trackedFileCount: 12)

        let roots = InsightsRootDisplay.roots(
            snapshotRoots: [snapshotRoot],
            configuredRootPaths: [
                "/Users/example/Desktop",
                "/Users/example/Documents",
                "/Users/example/Projects"
            ]
        )

        #expect(roots.map(\.path) == [
            "/Users/example/Desktop",
            "/Users/example/Documents",
            "/Users/example/Projects"
        ])
        #expect(roots[0].attributionSource == .estimated)
        #expect(roots[0].trackedFileCount == 0)
        #expect(InsightsRootDisplay.isUnrepresented(roots[0]))
        #expect(roots[1].trackedFileCount == 12)
        #expect(roots[2].attributionSource == .estimated)
        #expect(InsightsRootDisplay.isUnrepresented(roots[2]))
    }

    @Test("root display keeps snapshot roots when settings are unavailable")
    func rootDisplayKeepsSnapshotRootsWhenSettingsAreUnavailable() {
        let snapshotRoots = [
            makeRoot(path: "/Users/example/Documents", trackedFileCount: 12),
            makeRoot(path: "/Users/example/Projects", trackedFileCount: 3)
        ]

        let roots = InsightsRootDisplay.roots(
            snapshotRoots: snapshotRoots,
            configuredRootPaths: []
        )

        #expect(roots == snapshotRoots)
    }

    @Test("root display distinguishes exact empty roots from unrepresented roots")
    func rootDisplayDistinguishesExactEmptyRootsFromUnrepresentedRoots() {
        let exactEmptyRoot = IndexRootInsight(
            path: "/Users/example/Downloads",
            trackedFileCount: 0,
            directoryCount: 0,
            hiddenCount: 0,
            indexedContentBytes: 0,
            pathByteWeight: 0,
            estimatedIndexBytes: 0,
            attributionSource: .persistedExact
        )

        #expect(InsightsRootDisplay.hasNoIndexedRows(exactEmptyRoot))
        #expect(!InsightsRootDisplay.isUnrepresented(exactEmptyRoot))
    }

    @Test("index file display adds package overhead and sorts by size")
    func indexFileDisplayAddsPackageOverheadAndSortsBySize() {
        let items = InsightsIndexFileDisplay.items(
            sidecars: [
                IndexSidecarInsight(name: "manifest.json", allocatedBytes: 100),
                IndexSidecarInsight(name: "records.bin", allocatedBytes: 700)
            ],
            packageBytes: 1_000
        )

        #expect(items.map(\.name) == ["records.bin", "Package overhead", "manifest.json"])
        #expect(items.map(\.bytes) == [700, 200, 100])
        #expect(items[1].isPackageOverhead)
        #expect(items.allSatisfy { $0.packageBytes == 1_000 })
    }

    @Test("index files chart groups extra files and hit-tests the donut")
    func indexFilesChartGroupsExtraFilesAndHitTestsTheDonut() {
        let items = (0..<10).map { index in
            InsightsIndexFileDisplayItem(
                name: "file\(index).bin",
                bytes: UInt64(1_000 - index * 50),
                packageBytes: 10_000,
                isPackageOverhead: false
            )
        }
        let bounds = NSRect(x: 0, y: 0, width: 320, height: 126)
        let rect = InsightsIndexFilesChartLayout.chartRect(in: bounds)
        let firstSlicePoint = NSPoint(
            x: rect.midX,
            y: rect.midY - InsightsIndexFilesChartLayout.outerRadius(in: bounds) * 0.8
        )

        let slices = InsightsIndexFilesChartLayout.slices(from: items)
        #expect(slices.count == InsightsIndexFilesChartLayout.maximumVisibleSlices)
        #expect(slices.last?.name == "Other files")
        #expect(slices.last?.itemCount == 3)
        #expect(InsightsIndexFilesChartLayout.sliceIndex(at: firstSlicePoint, items: items, in: bounds) == 0)
        #expect(InsightsIndexFilesChartLayout.sliceIndex(at: NSPoint(x: rect.midX, y: rect.midY), items: items, in: bounds) == nil)
    }

    @Test("root access status identifies readable missing and non-folder roots")
    func rootAccessStatusIdentifiesReadableMissingAndNonFolderRoots() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("ATTInsightsRootAccess-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("not-a-folder", isDirectory: false)
        let missing = directory.appendingPathComponent("missing", isDirectory: true)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: file)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        #expect(InsightsRootAccessStatus.status(for: directory.path) == .readable)
        #expect(InsightsRootAccessStatus.status(for: file.path) == .notDirectory)
        #expect(InsightsRootAccessStatus.status(for: missing.path) == .missing)
    }

    @Test("root display uses active indexing placeholders")
    func rootDisplayUsesActiveIndexingPlaceholders() {
        #expect(InsightsRootDisplay.activePlaceholderLabel(for: makeStats(isIndexing: false, phase: .ready)) == nil)
        #expect(InsightsRootDisplay.activePlaceholderLabel(for: makeStats(isIndexing: true, phase: .scanning)) == "Indexing")
        #expect(InsightsRootDisplay.activePlaceholderLabel(for: makeStats(isIndexing: true, isReconciling: true, phase: .scanning)) == "Reconciling")
        #expect(InsightsRootDisplay.activePlaceholderLabel(for: makeStats(isIndexing: true, isReconciling: true, phase: .scanning, activityPresentation: .backgroundCatchUp)) == "Catching up")
        #expect(InsightsRootDisplay.activePlaceholderLabel(for: makeStats(isIndexing: true, isUpdating: true, phase: .scanning)) == "Updating")
        #expect(InsightsRootDisplay.activePlaceholderLabel(for: makeStats(isIndexing: true, phase: .optimizing)) == "Optimizing")
        #expect(InsightsRootDisplay.activePlaceholderLabel(for: makeStats(isIndexing: true, phase: .saving)) == "Saving")
    }

    @Test("query route summary handles zero cancellation and mixed routes")
    func queryRouteSummaryHandlesZeroCancellationAndMixedRoutes() {
        #expect(InsightsQueryRouteSummary.compactRouteSummary(SearchUsageCounters()) == "none")
        #expect(InsightsQueryRouteSummary.percentString(numerator: 0, denominator: 0) == "0%")

        var cancelledOnly = SearchUsageCounters(started: 3, cancelled: 3)
        #expect(InsightsQueryRouteSummary.compactRouteSummary(cancelledOnly) == "none")
        #expect(InsightsQueryRouteSummary.percentString(numerator: cancelledOnly.cancelled, denominator: cancelledOnly.started) == "100%")

        cancelledOnly.routeCounts[.sidecar] = 2
        #expect(InsightsQueryRouteSummary.compactRouteSummary(cancelledOnly) == "none")

        let mixed = SearchUsageCounters(
            completed: 7,
            routeCounts: [
                .sidecar: 2,
                .fullScan: 3,
                .mappedIndex: 1,
                .applicationCatalog: 1,
                .other: 4
            ]
        )
        #expect(InsightsQueryRouteSummary.routeCountString(mixed, .sidecar) == "2")
        #expect(InsightsQueryRouteSummary.applicationOtherRouteString(mixed) == "1 / 4")
        #expect(InsightsQueryRouteSummary.compactRouteSummary(mixed).contains("scan 3"))
    }

    @Test("default Insights layout fits the initial viewport")
    @MainActor
    func defaultInsightsLayoutFitsInitialViewport() throws {
        let suiteName = "AllTheThingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }

        let controller = InsightsWindowController(
            index: index,
            defaults: defaults,
            clearCachedIndexHandler: {}
        )
        let window = try #require(controller.window)
        window.setContentSize(InsightsWindowController.defaultContentSize)
        window.contentView?.layoutSubtreeIfNeeded()

        let contentRoot = try #require(findView(accessibilityIdentifier: "Insights.ContentView", in: window.contentView))
        contentRoot.layoutSubtreeIfNeeded()

        let tabControl = try #require(findTitlebarTabControl(in: window))
        let titlebarActions = try #require(findView(accessibilityIdentifier: "Insights.TitlebarActions", in: window.contentView))
        let summaryPage = try #require(findView(accessibilityIdentifier: "Insights.SummaryPage", in: contentRoot))
        let summaryTiles = try #require(findView(accessibilityIdentifier: "Insights.SummaryTiles", in: contentRoot))
        let healthCard = try #require(findView(accessibilityIdentifier: "Insights.HealthCard", in: summaryPage))
        let healthTiles = try #require(findView(accessibilityIdentifier: "Insights.HealthTiles", in: summaryPage))
        let healthFactsTable = try #require(findView(accessibilityIdentifier: "Insights.HealthFactsTable", in: summaryPage))

        #expect(window.contentView?.subviews.contains { $0 is NSScrollView } == false)
        #expect(contentRoot.fittingSize.height <= contentRoot.bounds.height + 1)
        #expect(contentRoot.fittingSize.width <= contentRoot.bounds.width + 1)
        #expect(tabControl.segmentCount == 4)
        #expect(tabControl.selectedSegment == 0)
        #expect(tabControl.segmentStyle == .separated)
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titlebarAccessoryViewControllers.isEmpty)
        #expect(findView(accessibilityIdentifier: "Insights.TabControl", in: contentRoot) == nil)
        #expect(findView(accessibilityIdentifier: "Insights.TitlebarActions", in: contentRoot) == nil)
        if let windowContentView = window.contentView {
            #expect(abs(tabControl.frame.midX - windowContentView.bounds.midX) <= 1)
        }
        #expect(abs(titlebarActions.frame.midY - tabControl.frame.midY) <= 1)
        #expect(titlebarActions.frame.minX >= tabControl.frame.maxX + 20)
        #expect(summaryPage.frame.maxY <= contentRoot.bounds.maxY - 17)
        #expect(summaryTiles.frame.minY >= summaryPage.bounds.minY)
        #expect(summaryTiles.frame.height >= 185)
        #expect(healthCard.frame.minY <= summaryPage.bounds.minY + 1)
        #expect(healthTiles.frame.maxX <= healthFactsTable.frame.minX - 12)
        #expect(abs(healthTiles.frame.width - healthFactsTable.frame.width) <= 1)
        #expect(healthFactsTable.frame.width <= summaryPage.frame.width * 0.55)
        #expect(healthFactsTable.frame.height <= 120)
        #expect(healthTiles.frame.height > healthFactsTable.frame.height)
    }

    @Test("Insights tab pages fit the initial viewport")
    @MainActor
    func insightsTabPagesFitInitialViewport() throws {
        let suiteName = "AllTheThingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }

        let controller = InsightsWindowController(
            index: index,
            defaults: defaults,
            clearCachedIndexHandler: {}
        )
        let window = try #require(controller.window)
        window.setContentSize(InsightsWindowController.defaultContentSize)
        window.contentView?.layoutSubtreeIfNeeded()

        let contentRoot = try #require(findView(accessibilityIdentifier: "Insights.ContentView", in: window.contentView))
        let tabControl = try #require(findTitlebarTabControl(in: window))
        let pageIdentifiers = [
            "Insights.SummaryPage",
            "Insights.IndexPage",
            "Insights.ActivityPage",
            "Insights.EnergyPage"
        ]
        let expectedTables = [
            "Insights.SummaryPage": "Insights.HealthFactsTable",
            "Insights.IndexPage": "Insights.StorageFactsTable",
            "Insights.ActivityPage": "Insights.ActivityFactsTable",
            "Insights.EnergyPage": "Insights.EnergyFactsTable"
        ]
        let expectedNestedViews = [
            "Insights.ActivityPage": "Insights.QueryPanel",
            "Insights.EnergyPage": "Insights.EnergyChart"
        ]

        for (index, identifier) in pageIdentifiers.enumerated() {
            tabControl.selectedSegment = index
            _ = tabControl.sendAction(tabControl.action, to: tabControl.target)
            window.contentView?.layoutSubtreeIfNeeded()
            contentRoot.layoutSubtreeIfNeeded()

            let page = try #require(findView(accessibilityIdentifier: identifier, in: contentRoot))
            #expect(contentRoot.fittingSize.height <= contentRoot.bounds.height + 1)
            #expect(contentRoot.fittingSize.width <= contentRoot.bounds.width + 1)
            #expect(page.frame.maxY <= contentRoot.bounds.maxY - 17)
            if let tableIdentifier = expectedTables[identifier] {
                #expect(findView(accessibilityIdentifier: tableIdentifier, in: page) != nil)
            }
            if let nestedIdentifier = expectedNestedViews[identifier] {
                #expect(findView(accessibilityIdentifier: nestedIdentifier, in: page) != nil)
            }

            if identifier == "Insights.IndexPage" {
                let storageCard = try #require(findView(accessibilityIdentifier: "Insights.StorageCard", in: page))
                let storageTreemap = try #require(findView(accessibilityIdentifier: "Insights.StorageTreemap", in: page))
                let storageFactsTable = try #require(findView(accessibilityIdentifier: "Insights.StorageFactsTable", in: page))
                let rootsLabel = try #require(findView(accessibilityIdentifier: "Insights.RootsLabel", in: page))
                let indexFilesLabel = try #require(findView(accessibilityIdentifier: "Insights.IndexFilesLabel", in: page))
                let rootsCard = try #require(findView(accessibilityIdentifier: "Insights.RootsCard", in: page))
                let indexFilesCard = try #require(findView(accessibilityIdentifier: "Insights.IndexFilesCard", in: page))
                let indexFilesChart = try #require(findView(accessibilityIdentifier: "Insights.IndexFilesChart", in: page))
                let storageTreemapFrame = storageTreemap.convert(storageTreemap.bounds, to: page)
                let storageFactsFrame = storageFactsTable.convert(storageFactsTable.bounds, to: page)
                let chartFrame = indexFilesChart.convert(indexFilesChart.bounds, to: page)
                #expect(storageTreemap.frame.height >= 170)
                #expect(storageFactsTable.frame.height <= 150)
                #expect(abs(storageFactsFrame.maxY - storageTreemapFrame.maxY) <= 1)
                #expect(storageCard.frame.maxY <= page.bounds.maxY + 1)
                #expect(rootsCard.frame.height >= 136)
                #expect(indexFilesCard.frame.minX >= rootsCard.frame.maxX + 10)
                #expect(abs(indexFilesCard.frame.minY - rootsCard.frame.minY) <= 1)
                #expect(abs(indexFilesCard.frame.maxY - rootsCard.frame.maxY) <= 1)
                #expect(indexFilesChart.frame.height >= 132)
                #expect(abs(rootsLabel.frame.minX - (rootsCard.frame.minX + 10)) <= 2)
                #expect(abs(indexFilesLabel.frame.minX - chartFrame.minX) <= 2)
                #expect(abs(chartFrame.midX - indexFilesCard.frame.midX) <= 1)
                #expect(findView(accessibilityIdentifier: "Insights.IndexFilesTable", in: page) == nil)
            }

            if identifier == "Insights.ActivityPage" {
                let queryPanel = try #require(findView(accessibilityIdentifier: "Insights.QueryPanel", in: page))
                let queryTitleLabel = try #require(findView(accessibilityIdentifier: "Insights.QueryTitleLabel", in: page))
                let queryRouteChart = try #require(findView(accessibilityIdentifier: "Insights.QueryRouteChart", in: page))
                let queryFactsTable = try #require(findView(accessibilityIdentifier: "Insights.QueryRouteFactsTable", in: page))
                let activityCard = try #require(findView(accessibilityIdentifier: "Insights.ActivityCard", in: page))
                let activityChart = try #require(findView(accessibilityIdentifier: "Insights.ActivityChart", in: page))
                let routeMatrixHeader = try #require(findView(accessibilityIdentifier: "Insights.RouteMatrixHeader", in: page))
                let previewRouteGroup = try #require(findView(accessibilityIdentifier: "Insights.PreviewRouteGroup", in: page))
                let finalRouteGroup = try #require(findView(accessibilityIdentifier: "Insights.FinalRouteGroup", in: page))
                let panelFrame = queryPanel.convert(queryPanel.bounds, to: page)
                let titleFrame = queryTitleLabel.convert(queryTitleLabel.bounds, to: page)
                let chartFrame = queryRouteChart.convert(queryRouteChart.bounds, to: page)
                let factsFrame = queryFactsTable.convert(queryFactsTable.bounds, to: page)
                let headerFrame = routeMatrixHeader.convert(routeMatrixHeader.bounds, to: page)
                let previewFrame = previewRouteGroup.convert(previewRouteGroup.bounds, to: page)
                let finalFrame = finalRouteGroup.convert(finalRouteGroup.bounds, to: page)

                #expect(findView(accessibilityIdentifier: "Insights.EnergyCard", in: page) == nil)
                #expect(queryPanel.frame.maxY <= page.bounds.maxY + 1)
                #expect(activityCard.frame.minY >= page.bounds.minY - 1)
                #expect(activityChart.frame.height >= 150)
                #expect(queryFactsTable.frame.width >= 600)
                #expect(queryFactsTable.frame.width <= page.bounds.width * 0.75)
                #expect(queryFactsTable.frame.height <= 150)
                #expect(chartFrame.width >= 600)
                #expect(chartFrame.width <= page.bounds.width * 0.75)
                #expect(abs(chartFrame.width - factsFrame.width) <= 1)
                #expect(queryRouteChart.frame.height <= 50)
                #expect(abs(chartFrame.midX - panelFrame.midX) <= 1)
                #expect(abs(factsFrame.midX - panelFrame.midX) <= 1)
                #expect(factsFrame.minX >= panelFrame.minX + 90)
                #expect(factsFrame.maxX <= panelFrame.maxX - 90)
                #expect(titleFrame.minY > chartFrame.maxY)
                #expect(chartFrame.minY > factsFrame.maxY)
                #expect(titleFrame.maxY <= panelFrame.maxY - 8)
                #expect(titleFrame.minY >= panelFrame.minY + 8)
                #expect(headerFrame.minY > previewFrame.maxY)
                #expect(previewFrame.minY > finalFrame.maxY)
                #expect(routeMatrixHeader.frame.height <= 32)
                #expect(previewRouteGroup.frame.height <= 58)
                #expect(finalRouteGroup.frame.height <= 58)
            }

            if identifier == "Insights.EnergyPage" {
                let energyCard = try #require(findView(accessibilityIdentifier: "Insights.EnergyCard", in: page))
                let energyTiles = try #require(findView(accessibilityIdentifier: "Insights.EnergyTiles", in: page))
                let energyRange = try #require(findView(accessibilityIdentifier: "Insights.EnergyRangeControl", in: page) as? NSSegmentedControl)
                let energyChart = try #require(findView(accessibilityIdentifier: "Insights.EnergyChart", in: page))
                let energyFactsTable = try #require(findView(accessibilityIdentifier: "Insights.EnergyFactsTable", in: page))

                #expect(findView(accessibilityIdentifier: "Insights.MaintenanceCard", in: page) == nil)
                #expect(findView(accessibilityIdentifier: "Insights.MaintenanceCostChart", in: page) == nil)
                #expect(energyCard.frame.maxY <= page.bounds.maxY + 1)
                #expect(energyCard.frame.minY >= page.bounds.minY - 1)
                #expect(abs(energyCard.frame.height - page.bounds.height) <= 1)
                #expect(energyCard.frame.height >= 430)
                #expect(energyTiles.frame.height >= 150)
                #expect((0..<energyRange.segmentCount).map { energyRange.label(forSegment: $0) } == ["1h", "1d", "3m"])
                #expect(energyRange.frame.maxY <= energyTiles.frame.minY - 8)
                #expect(abs(energyRange.frame.midX - energyChart.frame.midX) <= 1)
                #expect(energyChart.frame.height >= 210)
                #expect(energyFactsTable.frame.width >= 280)
                #expect(energyFactsTable.frame.minY >= energyChart.frame.minY - 1)
                #expect(energyFactsTable.frame.maxY <= energyChart.frame.maxY + 1)
            }
        }
    }

    @Test("Insights opening placement centers in the visible screen")
    @MainActor
    func insightsOpeningPlacementCentersInVisibleScreen() {
        let visibleFrame = NSRect(x: 40, y: 30, width: 760, height: 520)
        let proposedFrame = NSRect(x: -400, y: 10, width: 300, height: 200)

        let frame = InsightsWindowController.openingFrameFittingVisibleScreen(
            proposedFrame,
            visibleFrame: visibleFrame
        )

        #expect(frame.origin == NSPoint(x: 270, y: 190))
        #expect(frame.size == proposedFrame.size)
    }

    @Test("Insights opening placement clamps oversized frames")
    @MainActor
    func insightsOpeningPlacementClampsOversizedFrames() {
        let visibleFrame = NSRect(x: 40, y: 30, width: 760, height: 520)
        let oversizedFrame = NSRect(x: -400, y: 10, width: 1200, height: 900)

        let frame = InsightsWindowController.openingFrameFittingVisibleScreen(
            oversizedFrame,
            visibleFrame: visibleFrame
        )

        #expect(frame == NSRect(x: 58, y: 48, width: 724, height: 484))
        #expect(frame.minX >= visibleFrame.minX)
        #expect(frame.maxX <= visibleFrame.maxX)
        #expect(frame.minY >= visibleFrame.minY)
        #expect(frame.maxY <= visibleFrame.maxY)
        #expect(frame.width <= visibleFrame.width)
        #expect(frame.height <= visibleFrame.height)
    }

    @Test("Insights resize constraint preserves visible positions")
    @MainActor
    func insightsResizeConstraintPreservesVisiblePositions() {
        let visibleFrame = NSRect(x: 40, y: 30, width: 760, height: 520)
        let proposedFrame = NSRect(x: 120, y: 100, width: 400, height: 300)

        let frame = InsightsWindowController.constrainedFrameFittingVisibleScreen(
            proposedFrame,
            visibleFrame: visibleFrame
        )

        #expect(frame == proposedFrame)
    }

    @Test("Insights resize constraint nudges off-screen origins")
    @MainActor
    func insightsResizeConstraintNudgesOffScreenOrigins() {
        let visibleFrame = NSRect(x: 40, y: 30, width: 760, height: 520)
        let proposedFrame = NSRect(x: -20, y: 400, width: 400, height: 300)

        let frame = InsightsWindowController.constrainedFrameFittingVisibleScreen(
            proposedFrame,
            visibleFrame: visibleFrame
        )

        #expect(frame == NSRect(x: 58, y: 232, width: 400, height: 300))
        #expect(frame.minX >= visibleFrame.minX)
        #expect(frame.maxX <= visibleFrame.maxX)
        #expect(frame.minY >= visibleFrame.minY)
        #expect(frame.maxY <= visibleFrame.maxY)
    }

    @Test("activity chart reserves space for the legend")
    func activityChartReservesSpaceForLegend() {
        let bounds = NSRect(x: 0, y: 0, width: 420, height: 104)

        let plot = InsightsActivityChartLayout.plotRect(in: bounds)
        let legend = InsightsActivityChartLayout.legendRect(in: bounds)

        #expect(plot.minY >= bounds.minY)
        #expect(plot.maxY <= legend.minY)
        #expect(legend.maxY <= bounds.maxY)
        #expect(plot.height > legend.height)
    }

    @Test("activity chart bucket hit testing follows plotted bars")
    func activityChartBucketHitTestingFollowsPlottedBars() {
        let bounds = NSRect(x: 0, y: 0, width: 420, height: 104)

        let buckets = InsightsActivityChartLayout.bucketRects(bucketCount: 4, in: bounds)

        #expect(buckets.count == 4)
        #expect(InsightsActivityChartLayout.bucketIndex(at: center(of: buckets[0]), bucketCount: 4, in: bounds) == 0)
        #expect(InsightsActivityChartLayout.bucketIndex(at: center(of: buckets[3]), bucketCount: 4, in: bounds) == 3)
        #expect(InsightsActivityChartLayout.bucketIndex(at: NSPoint(x: 1, y: bounds.maxY - 1), bucketCount: 4, in: bounds) == nil)
    }

    @Test("energy timeline separates CPU and wakeup plots and selects the nearest sample")
    func energyTimelineSeparatesCPUAndWakeupPlotsAndSelectsNearestSample() {
        let bounds = NSRect(x: 0, y: 0, width: 420, height: 120)
        let completedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [
            EnergyUsageIntervalSample(completedAt: completedAt.addingTimeInterval(-30), duration: 30, cpuTime: 3, wakeups: 5, mode: .foreground),
            EnergyUsageIntervalSample(completedAt: completedAt, duration: 30, cpuTime: 6, wakeups: 8, mode: .background)
        ]

        let plot = InsightsEnergyTimelineLayout.plotRect(in: bounds)
        let cpuPlot = InsightsEnergyTimelineLayout.cpuPlotRect(in: bounds)
        let wakeupsPlot = InsightsEnergyTimelineLayout.wakeupsPlotRect(in: bounds)
        let legend = InsightsEnergyTimelineLayout.legendRect(in: bounds)
        let rects = InsightsEnergyTimelineLayout.sampleRects(samples: samples, in: bounds)

        #expect(plot.minY >= bounds.minY)
        #expect(cpuPlot.minY == plot.minY)
        #expect(cpuPlot.maxY < wakeupsPlot.minY)
        #expect(wakeupsPlot.maxY == plot.maxY)
        #expect(cpuPlot.width == wakeupsPlot.width)
        #expect(plot.maxY <= legend.minY)
        #expect(legend.maxY <= bounds.maxY)
        #expect(rects.count == 2)
        #expect(InsightsEnergyTimelineLayout.sampleIndex(at: center(of: rects[1]), samples: samples, in: bounds) == 1)
        #expect(InsightsEnergyTimelineLayout.sampleIndex(at: NSPoint(x: 1, y: bounds.maxY - 1), samples: samples, in: bounds) == nil)

        let selectionBoundary = (rects[0].midX + rects[1].midX) / 2
        #expect(InsightsEnergyTimelineLayout.sampleIndex(
            at: NSPoint(x: selectionBoundary - 0.1, y: plot.midY),
            samples: samples,
            in: bounds
        ) == 0)
        #expect(InsightsEnergyTimelineLayout.sampleIndex(
            at: NSPoint(x: selectionBoundary + 0.1, y: plot.midY),
            samples: samples,
            in: bounds
        ) == 1)

        let cpuPoints = InsightsEnergyTimelineLayout.cpuLoadPoints(
            loads: samples.map(\.cpuLoad),
            maxLoad: 1,
            slots: rects,
            plot: cpuPlot
        )
        #expect(cpuPoints.count == samples.count + 2)
        #expect(cpuPoints[0].x == rects[0].minX)
        #expect(cpuPoints[1].x == rects[0].midX)
        #expect(cpuPoints[2].x == rects[1].midX)
        #expect(cpuPoints[3].x == rects[1].maxX)
        #expect(rects[0].maxX == rects[1].minX)
    }

    @Test("energy CPU timeline uses one-core scale floor before autoscaling above it")
    func energyCPUTimelineUsesOneCoreScaleFloorBeforeAutoscalingAboveIt() {
        #expect(InsightsEnergyChartView.cpuLoadScaleMaximum([0.021, 0.002]) == 1)
        #expect(InsightsEnergyChartView.cpuLoadScaleMaximum([0, .nan, -.infinity]) == 1)
        #expect(InsightsEnergyChartView.cpuLoadScaleMaximum([0.5, 1.4]) == 1.4)
    }

    @Test("energy CPU stack uses the total timeline as its shared denominator")
    func energyCPUStackUsesTotalTimelineAsSharedDenominator() {
        let energy = EnergyUsageBreakdown(
            foreground: EnergyUsageCounters(wallTime: 30, cpuTime: 3),
            background: EnergyUsageCounters(wallTime: 30, cpuTime: 6)
        )

        #expect(energy.total.averageCPULoad == 0.15)
        #expect(InsightsEnergyChartView.backgroundCPULoadContribution(energy) == 0.1)
    }

    @Test("energy calendar lays out three month weekday grid with sparse buckets")
    func energyCalendarLaysOutThreeMonthWeekdayGridWithSparseBuckets() throws {
        let bounds = NSRect(x: 0, y: 0, width: 350, height: 140)
        let buckets = (1...14).map { day in
            DailyUsageBucket(day: String(format: "2026-06-%02d", day))
        }

        let referenceDate = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 4
        )))
        let grid = InsightsEnergyCalendarLayout.layout(buckets: buckets, in: bounds, referenceDate: referenceDate)
        let items = grid.items
        let firstBucket = try #require(items.first { $0.bucketIndex == 0 })
        let seventhBucket = try #require(items.first { $0.bucketIndex == 6 })
        let eighthBucket = try #require(items.first { $0.bucketIndex == 7 })

        #expect(items.count == 92)
        #expect(firstBucket.center.x == seventhBucket.center.x)
        #expect(eighthBucket.center.x > firstBucket.center.x)
        #expect(items.allSatisfy { bounds.contains($0.center) })
        #expect(items.allSatisfy { bounds.contains($0.cellRect.origin) })
        #expect(grid.weekdayLabels.map(\.title) == ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
        #expect(grid.monthLabels.map(\.title) == ["May", "Jun", "Jul"])
        #expect(grid.monthSeparators.count == 2)
        #expect(grid.monthSeparators[0].start.x < grid.monthSeparators[1].start.x)
        #expect(grid.monthSeparators.allSatisfy { separator in
            separator.start.x == separator.end.x
                && separator.start.y < separator.end.y
                && separator.start.x >= bounds.minX
                && separator.start.x <= bounds.maxX
                && separator.start.y >= bounds.minY
                && separator.end.y <= bounds.maxY
        })
        #expect(items.filter { $0.bucketIndex != nil }.count == 14)
        #expect(InsightsEnergyCalendarLayout.itemIndex(at: firstBucket.center, in: items) == 0)
    }

    @Test("energy calendar color uses absolute background intensity bands")
    func energyCalendarColorUsesAbsoluteBackgroundIntensityBands() throws {
        let low = try #require(
            InsightsEnergyChartView.calendarColor(backgroundIntensity: 0.2)
                .usingColorSpace(.sRGB)
        )
        let high = try #require(
            InsightsEnergyChartView.calendarColor(backgroundIntensity: 2)
                .usingColorSpace(.sRGB)
        )

        #expect(low.greenComponent > low.redComponent)
        #expect(high.redComponent > high.greenComponent)
    }

    @Test("energy calendar size uses activity while color uses background intensity")
    func energyCalendarSizeUsesActivityWhileColorUsesBackgroundIntensity() throws {
        let lowActivityHighBackground = DailyUsageBucket(
            day: "2026-07-01",
            searches: SearchUsageCounters(completed: 1),
            energy: EnergyUsageBreakdown(
                background: EnergyUsageCounters(wallTime: 60, cpuTime: 12, wakeups: 120)
            )
        )
        let highActivityLowBackground = DailyUsageBucket(
            day: "2026-07-02",
            searches: SearchUsageCounters(
                completed: 8,
                candidateRowsExamined: 4_000,
                scannedRowsExamined: 2_000
            ),
            health: IndexHealthCounters(incrementalRefreshBatches: 3),
            maintenance: IndexMaintenanceCostCounters(
                total: IndexMaintenanceOperationCounters(
                    operations: 2,
                    paths: 20,
                    records: 500,
                    visited: 1_500
                )
            )
        )

        let baseline = InsightsEnergyChartView.calendarActivityBaseline(scores: [
            InsightsEnergyChartView.calendarActivityScore(lowActivityHighBackground),
            InsightsEnergyChartView.calendarActivityScore(highActivityLowBackground)
        ])
        let lowActivityRadius = InsightsEnergyChartView.calendarRadiusScale(
            activity: InsightsEnergyChartView.calendarActivityScore(lowActivityHighBackground),
            baseline: baseline
        )
        let highActivityRadius = InsightsEnergyChartView.calendarRadiusScale(
            activity: InsightsEnergyChartView.calendarActivityScore(highActivityLowBackground),
            baseline: baseline
        )

        #expect(highActivityRadius > lowActivityRadius)
        #expect(
            InsightsEnergyChartView.backgroundEnergyIntensity(lowActivityHighBackground)
                > InsightsEnergyChartView.backgroundEnergyIntensity(highActivityLowBackground)
        )

        let noBackgroundColor = try #require(
            InsightsEnergyChartView.calendarColor(
                backgroundIntensity: InsightsEnergyChartView.backgroundEnergyIntensity(highActivityLowBackground)
            )
                .usingColorSpace(.sRGB)
        )
        let highBackgroundColor = try #require(
            InsightsEnergyChartView.calendarColor(
                backgroundIntensity: InsightsEnergyChartView.backgroundEnergyIntensity(lowActivityHighBackground)
            )
                .usingColorSpace(.sRGB)
        )

        #expect(noBackgroundColor.greenComponent > noBackgroundColor.redComponent)
        #expect(highBackgroundColor.redComponent >= highBackgroundColor.greenComponent)
    }

    @Test("route mix layout hit testing follows visible route segments")
    func routeMixLayoutHitTestingFollowsVisibleRouteSegments() {
        let bounds = NSRect(x: 0, y: 0, width: 620, height: 76)
        let preview = SearchUsageCounters(routeCounts: [
            .sidecar: 4,
            .mappedIndex: 34,
            .applicationCatalog: 2
        ])
        let final = SearchUsageCounters(routeCounts: [
            .sidecar: 3,
            .mappedIndex: 12,
            .applicationCatalog: 5
        ])

        let rows = InsightsRouteMixLayout.barRows(in: bounds)
        let segments = InsightsRouteMixLayout.segments(preview: preview, final: final, in: bounds)
        let previewSegments = segments.filter { $0.phase == .preview }
        let finalSegments = segments.filter { $0.phase == .final }

        #expect(rows.map(\.phase) == [.preview, .final])
        #expect(previewSegments.map(\.route) == [.sidecar, .mappedIndex])
        #expect(finalSegments.map(\.route) == [.sidecar, .mappedIndex, .applicationCatalog])
        #expect(InsightsRouteMixLayout.hitTarget(at: center(of: previewSegments[0].rect), preview: preview, final: final, in: bounds) == InsightsRouteMixHoverTarget(phase: .preview, route: .sidecar))
        #expect(InsightsRouteMixLayout.hitTarget(at: center(of: previewSegments[1].rect), preview: preview, final: final, in: bounds) == InsightsRouteMixHoverTarget(phase: .preview, route: .mappedIndex))
        #expect(InsightsRouteMixLayout.hitTarget(at: center(of: finalSegments[2].rect), preview: preview, final: final, in: bounds) == InsightsRouteMixHoverTarget(phase: .final, route: .applicationCatalog))
        #expect(InsightsRouteMixLayout.hitTarget(at: NSPoint(x: bounds.maxX + 1, y: bounds.midY), preview: preview, final: final, in: bounds) == nil)
    }

    @Test("hover placards can escape a source section while fitting window content")
    func hoverPlacardsCanEscapeSourceSectionWhileFittingWindowContent() {
        let sourceSection = NSRect(x: 0, y: 0, width: 120, height: 50)
        let contentBounds = NSRect(x: 0, y: 0, width: 800, height: 600)

        let rect = InsightsHoverCardLayout.placardRect(
            lines: [
                "Documents",
                "100% of estimated index package",
                "900,000 files"
            ],
            near: NSPoint(x: sourceSection.maxX - 6, y: sourceSection.midY),
            in: contentBounds
        )

        #expect(rect.maxX > sourceSection.maxX)
        #expect(rect.maxX <= contentBounds.maxX - 8)
        #expect(rect.minY >= contentBounds.minY + 8)
    }

    @Test("hover placards support structured label value rows")
    func hoverPlacardsSupportStructuredLabelValueRows() {
        let rows = [
            HoverLine(index: 0, rawValue: "2026-07-04"),
            HoverLine(index: 1, rawValue: "Activity\t64.8"),
            HoverLine(index: 2, rawValue: ""),
            HoverLine(index: 3, rawValue: "Background CPU\t242.48 s")
        ]
        let size = InsightsHoverCardLayout.measuredSize(for: rows)
        let rect = InsightsHoverCardLayout.placardRect(
            lines: [
                "2026-07-04",
                "Activity\t64.8",
                "",
                "Background CPU\t242.48 s"
            ],
            near: NSPoint(x: 780, y: 580),
            in: NSRect(x: 0, y: 0, width: 800, height: 600)
        )

        #expect(rows[1] == .row(label: "Activity", value: "64.8"))
        #expect(rows[2] == .separator)
        #expect(size.height == InsightsHoverCardLayout.lineHeight * 3 + InsightsHoverCardLayout.separatorHeight)
        #expect(rect.maxX <= 792)
        #expect(rect.maxY <= 592)
    }

    @Test("Insights panel palette keeps light panels lighter than dark panels")
    @MainActor
    func insightsPanelPaletteKeepsLightPanelsLighterThanDarkPanels() throws {
        let lightAppearance = try #require(NSAppearance(named: .aqua))
        let darkAppearance = try #require(NSAppearance(named: .darkAqua))

        let lightCard = luminance(
            InsightsPanelPalette.cardBackgroundColor(isDark: false),
            appearance: lightAppearance
        )
        let darkCard = luminance(
            InsightsPanelPalette.cardBackgroundColor(isDark: true),
            appearance: darkAppearance
        )
        let lightMetric = luminance(
            InsightsPanelPalette.tileBackgroundColor(style: .metric, isDark: false),
            appearance: lightAppearance
        )
        let darkMetric = luminance(
            InsightsPanelPalette.tileBackgroundColor(style: .metric, isDark: true),
            appearance: darkAppearance
        )
        let lightChart = luminance(
            InsightsPanelPalette.chartBackgroundColor(isDark: false),
            appearance: lightAppearance
        )
        let darkChart = luminance(
            InsightsPanelPalette.chartBackgroundColor(isDark: true),
            appearance: darkAppearance
        )

        #expect(lightCard > darkCard + 0.3)
        #expect(lightMetric > darkMetric + 0.3)
        #expect(lightChart > darkChart + 0.3)
    }

    private func center(of rect: NSRect) -> NSPoint {
        NSPoint(x: rect.midX, y: rect.midY)
    }

    private func makeRoot(path: String, trackedFileCount: Int) -> IndexRootInsight {
        IndexRootInsight(
            path: path,
            trackedFileCount: trackedFileCount,
            directoryCount: 1,
            hiddenCount: 0,
            indexedContentBytes: 1024,
            pathByteWeight: 512,
            estimatedIndexBytes: 256,
            attributionSource: .persistedExact
        )
    }

    private func makeStats(
        isIndexing: Bool,
        isReconciling: Bool = false,
        isUpdating: Bool = false,
        phase: IndexPhase,
        activityPresentation: IndexActivityPresentation = .foreground
    ) -> IndexStats {
        IndexStats(
            indexedCount: 0,
            isIndexing: isIndexing,
            isReconciling: isReconciling,
            isUpdating: isUpdating,
            phase: phase,
            status: "",
            lastUpdated: Date(),
            activityPresentation: activityPresentation
        )
    }

    @MainActor
    private func findView(accessibilityIdentifier identifier: String, in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        for subview in view.subviews {
            if let match = findView(accessibilityIdentifier: identifier, in: subview) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private func findTitlebarTabControl(in window: NSWindow) -> NSSegmentedControl? {
        findView(accessibilityIdentifier: "Insights.TabControl", in: window.contentView) as? NSSegmentedControl
    }

    @MainActor
    private func luminance(_ color: NSColor, appearance: NSAppearance) -> CGFloat {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.deviceRGB) ?? color
        }
        return 0.2126 * resolved.redComponent
            + 0.7152 * resolved.greenComponent
            + 0.0722 * resolved.blueComponent
    }
}
