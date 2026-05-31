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
        #expect(roots[1].trackedFileCount == 12)
        #expect(roots[2].attributionSource == .estimated)
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
        window.setContentSize(NSSize(width: 980, height: 720))
        window.contentView?.layoutSubtreeIfNeeded()

        let scrollView = try #require(findScrollView(in: window.contentView))
        scrollView.layoutSubtreeIfNeeded()
        let documentView = try #require(scrollView.documentView)
        documentView.layoutSubtreeIfNeeded()

        #expect(documentView.fittingSize.height <= scrollView.contentView.bounds.height + 1)
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
}
