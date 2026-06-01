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
        #expect(InsightsRootDisplay.activePlaceholderLabel(for: makeStats(isIndexing: true, isUpdating: true, phase: .scanning)) == "Updating")
        #expect(InsightsRootDisplay.activePlaceholderLabel(for: makeStats(isIndexing: true, phase: .optimizing)) == "Optimizing")
        #expect(InsightsRootDisplay.activePlaceholderLabel(for: makeStats(isIndexing: true, phase: .saving)) == "Saving")
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

        let scrollView = try #require(findScrollView(in: window.contentView))
        scrollView.layoutSubtreeIfNeeded()
        let documentView = try #require(scrollView.documentView)
        documentView.layoutSubtreeIfNeeded()

        #expect(documentView.fittingSize.height <= scrollView.contentView.bounds.height + 1)
        #expect(documentView.fittingSize.width <= scrollView.contentView.bounds.width + 1)
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
        phase: IndexPhase
    ) -> IndexStats {
        IndexStats(
            indexedCount: 0,
            isIndexing: isIndexing,
            isReconciling: isReconciling,
            isUpdating: isUpdating,
            phase: phase,
            status: "",
            lastUpdated: Date()
        )
    }

    @MainActor
    private func findScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scrollView = view as? NSScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let scrollView = findScrollView(in: subview) {
                return scrollView
            }
        }
        return nil
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
