@testable import AllTheThings
import AppKit
import ATTCore
import Foundation
import Testing

@Suite("Search toolbar")
struct SearchToolbarTests {
    @Test("toolbar opens settings and insights instead of indexing actions")
    @MainActor
    func toolbarOpensSettingsAndInsightsInsteadOfIndexingActions() throws {
        let index = FileIndex(
            applicationName: "AllTheThingsToolbarTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }

        let controller = SearchWindowController(index: index)
        let view = try #require(controller.window?.contentViewController?.view)
        let tooltips = Set(buttons(in: view).compactMap(\.toolTip))

        #expect(tooltips.contains("Open Settings"))
        #expect(tooltips.contains("Open Insights"))
        #expect(tooltips.contains("Open selected file"))
        #expect(tooltips.contains("Reveal selected file in Finder"))
        #expect(tooltips.contains("Copy selected path"))
        #expect(!tooltips.contains("Add indexed folder"))
        #expect(!tooltips.contains("Reindex scopes"))
    }

    @Test("zero-row root recovery only retries readable empty roots")
    func zeroRowRootRecoveryOnlyRetriesReadableEmptyRoots() {
        let roots = [
            makeRoot(path: "/Users/example/Documents", trackedFileCount: 12),
            makeRoot(path: "/Users/example/Downloads", trackedFileCount: 0)
        ]

        let paths = SearchWindowController.zeroRowRootRecoveryPaths(
            snapshotRoots: roots,
            configuredRootPaths: [
                "/Users/example/Desktop",
                "/Users/example/Documents",
                "/Users/example/Downloads",
                "/Users/example/Downloads"
            ],
            accessStatus: { path in
                path.hasSuffix("Downloads") ? .readable : .notReadable
            }
        )

        #expect(paths == ["/Users/example/Downloads"])
    }

    @Test("zero-row root recovery candidates come only from unbuilt configured roots")
    func zeroRowRootRecoveryCandidatesComeOnlyFromUnbuiltConfiguredRoots() {
        let roots = [
            makeRoot(path: "/Users/example/Documents", trackedFileCount: 12),
            makeRoot(path: "/Users/example/Downloads", trackedFileCount: 0)
        ]

        let paths = SearchWindowController.zeroRowRootRecoveryCandidatePaths(
            snapshotRoots: roots,
            configuredRootPaths: [
                "/Users/example/Desktop",
                "/Users/example/Documents",
                "/Users/example/Downloads",
                "/Users/example/Downloads"
            ]
        )

        #expect(paths == ["/Users/example/Desktop", "/Users/example/Downloads"])
    }

    @MainActor
    private func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        let current = (view as? NSButton).map { [$0] } ?? []
        return view.subviews.reduce(current) { partial, subview in
            partial + buttons(in: subview)
        }
    }

    private func makeRoot(path: String, trackedFileCount: Int) -> IndexRootInsight {
        IndexRootInsight(
            path: path,
            trackedFileCount: trackedFileCount,
            directoryCount: trackedFileCount == 0 ? 0 : 1,
            hiddenCount: 0,
            indexedContentBytes: trackedFileCount == 0 ? 0 : 1024,
            pathByteWeight: trackedFileCount == 0 ? 0 : 512,
            estimatedIndexBytes: trackedFileCount == 0 ? 0 : 256,
            attributionSource: .persistedExact
        )
    }
}
