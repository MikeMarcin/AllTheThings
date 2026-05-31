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

    @MainActor
    private func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        let current = (view as? NSButton).map { [$0] } ?? []
        return view.subviews.reduce(current) { partial, subview in
            partial + buttons(in: subview)
        }
    }
}
