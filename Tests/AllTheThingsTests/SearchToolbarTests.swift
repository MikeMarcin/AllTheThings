@testable import AllTheThings
import AppKit
import ATTCore
import Foundation
import Testing

@Suite("Search toolbar")
struct SearchToolbarTests {
    @Test("titlebar actions use unified toolbar with centered title and open settings and insights instead of indexing actions")
    @MainActor
    func titlebarActionsUseUnifiedToolbarWithCenteredTitleAndOpenSettingsAndInsightsInsteadOfIndexingActions() throws {
        let index = FileIndex(
            applicationName: "AllTheThingsToolbarTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }

        let controller = SearchWindowController(index: index)
        let window = try #require(controller.window)
        let view = try #require(controller.window?.contentViewController?.view)
        let toolbar = try #require(window.toolbar)
        let contentTooltips = Set(buttons(in: view).compactMap(\.toolTip))
        let titlebarTooltips = Set(toolbar.items.compactMap(\.toolTip))
        let centeredTitleLabels = textFields(in: view).filter { $0.stringValue == window.title }

        #expect(window.toolbarStyle == .unified)
        #expect(window.titleVisibility == .hidden)
        #expect(toolbar.displayMode == .iconOnly)
        #expect(toolbar.sizeMode == .regular)
        #expect(window.titlebarAccessoryViewControllers.isEmpty)
        #expect(centeredTitleLabels.count == 1)
        #expect(centeredTitleLabels.first?.alignment == .center)
        #expect(titlebarTooltips.contains("Open Settings"))
        #expect(titlebarTooltips.contains("Open Insights"))
        #expect(titlebarTooltips.contains("Open selected file"))
        #expect(titlebarTooltips.contains("Reveal selected file in Finder"))
        #expect(titlebarTooltips.contains("Copy selected path"))
        #expect(!contentTooltips.contains("Open Settings"))
        #expect(!contentTooltips.contains("Open Insights"))
        #expect(!titlebarTooltips.contains("Add indexed folder"))
        #expect(!titlebarTooltips.contains("Reindex scopes"))
    }

    @Test("expanded mascot layout keeps visible pixels onscreen")
    @MainActor
    func expandedMascotLayoutKeepsVisiblePixelsOnscreen() {
        let footerFrame = mascotFooterFrame()
        let expandedFrame = ExpandedMascotLayout.expandedFrame(footerFrame: footerFrame)

        #expect(expandedFrame.minX == -ExpandedMascotLayout.operationVisibleContentLeadingInset)
        #expect(ExpandedMascotLayout.visibleContentLeadingX(footerFrame: footerFrame) == ExpandedMascotLayout.visibleLeadingInset)
        #expect(expandedFrame.width == OperationMascotCoordinator.expandedDisplaySize)
        #expect(expandedFrame.height == OperationMascotCoordinator.displayHeight(for: expandedFrame.width))
    }

    @Test("expanded mascot target scales and translates from collapsed target")
    @MainActor
    func expandedMascotTargetScalesAndTranslatesFromCollapsedTarget() {
        let footerFrame = mascotFooterFrame()
        let collapsedTarget = ExpandedMascotLayout.collapsedTarget(footerFrame: footerFrame)
        let expandedTarget = ExpandedMascotLayout.expandedTarget()

        #expect(collapsedTarget.displaySize == OperationMascotCoordinator.statusDisplaySize)
        #expect(expandedTarget.displaySize == OperationMascotCoordinator.expandedDisplaySize)
        #expect(expandedTarget.anchorX != collapsedTarget.anchorX)
        #expect(expandedTarget.bottomConstraintConstant != collapsedTarget.bottomConstraintConstant)
    }

    @Test("expanded mascot is lifted above the footer row")
    @MainActor
    func expandedMascotIsLiftedAboveTheFooterRow() {
        let footerFrame = mascotFooterFrame()
        let expandedTarget = ExpandedMascotLayout.expandedTarget()
        let expandedFrame = ExpandedMascotLayout.expandedFrame(footerFrame: footerFrame)

        #expect(expandedTarget.bottomConstraintConstant == -ExpandedMascotLayout.expandedFooterLift)
        #expect(ExpandedMascotLayout.expandedFooterLift == OperationMascotCoordinator.footerSlotHeight)
        #expect(expandedFrame.minY == footerFrame.minY + OperationMascotCoordinator.footerSlotHeight)
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

    @Test("background catch up does not present as foreground reconcile")
    func backgroundCatchUpDoesNotPresentAsForegroundReconcile() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 1_012)
        let stats = IndexStats(
            indexedCount: 10,
            isIndexing: true,
            isReconciling: true,
            phase: .scanning,
            discoveredCount: 4,
            searchableCount: 10,
            status: "Catching up changes",
            lastUpdated: now,
            activeOperationStartedAt: startedAt,
            activityPresentation: .backgroundCatchUp
        )

        let status = SearchWindowPresentation.indexStatusText(
            indexedRootsIsEmpty: false,
            fseventCatchUpStartedAt: nil,
            stats: stats,
            now: now
        )
        let footerStatus = SearchWindowPresentation.indexStatusFooterText(
            indexedRootsIsEmpty: false,
            fseventCatchUpStartedAt: nil,
            stats: stats,
            now: now
        )

        #expect(status.contains("Catching up changes"))
        #expect(footerStatus.operationText == "Catching up changes • 12s")
        #expect(footerStatus.detailText == "10 searchable")
        #expect(footerStatus.combinedText == status)
        #expect(!status.contains("Reconciling"))
        #expect(!SearchWindowPresentation.isImportantMascotOperation(stats))
        #expect(SearchWindowPresentation.persistentMascotAnimation(stats: stats, hasActiveSearch: false) == .idle)
        #expect(SearchWindowPresentation.persistentMascotAnimation(stats: stats, hasActiveSearch: true) == .searching)
        #expect(SearchWindowPresentation.persistentMascotAnimation(
            stats: stats,
            hasActiveSearch: true,
            isRefiningSearchResults: true
        ) == .searchRefining)
    }

    @Test("search timing presentation stays available independent of query text")
    func searchTimingPresentationStaysAvailableIndependentOfQueryText() {
        #expect(SearchWindowPresentation.shouldShowSearchElapsedText(
            displayedSearchSignatureIsSet: true,
            queryElapsed: 0.042,
            initialQueryElapsed: nil,
            isRefiningSearchResults: false,
            hasFinalSearchTiming: true
        ))
        #expect(SearchWindowPresentation.searchElapsedText(
            queryElapsed: 0.042,
            initialQueryElapsed: nil,
            isRefiningSearchResults: false,
            hasFinalSearchTiming: true
        ) == "42ms")
        #expect(SearchWindowPresentation.searchElapsedText(
            queryElapsed: 1.2,
            initialQueryElapsed: 0.08,
            isRefiningSearchResults: true,
            hasFinalSearchTiming: false
        ) == "80ms (1.20s refining)")
        #expect(SearchWindowPresentation.searchElapsedText(
            queryElapsed: 1.2,
            initialQueryElapsed: 0.08,
            isRefiningSearchResults: false,
            hasFinalSearchTiming: true
        ) == "80ms (1.20s)")
        let footerText = SearchWindowPresentation.detailedFooterText(
            shownText: "2,000 shown / 955,841 matches",
            operationText: "Ready",
            detailText: "Caught up 974,301 files",
            appSearchScopeText: nil,
            memoryStatusText: "Memory 215.8 MB",
            searchElapsedText: "80ms (1.20s)"
        )
        #expect(footerText.centerText == "2,000 shown / 955,841 matches")
        #expect(footerText.operationText == "Ready • 80ms (1.20s)")
        #expect(footerText.rightText == "Caught up 974,301 files • Memory 215.8 MB")
        #expect(!SearchWindowPresentation.shouldShowSearchElapsedText(
            displayedSearchSignatureIsSet: false,
            queryElapsed: 0.042,
            initialQueryElapsed: nil,
            isRefiningSearchResults: false,
            hasFinalSearchTiming: true
        ))
    }

    @Test("search run reconciliation keeps pending previews applyable")
    func searchRunReconciliationKeepsPendingPreviewsApplyable() {
        #expect(SearchRunReconciliation.fullCancellationKeepsSearchActive(
            hasPendingPreview: true,
            tokenCancelled: false
        ))
        #expect(!SearchRunReconciliation.fullCancellationKeepsSearchActive(
            hasPendingPreview: true,
            tokenCancelled: true
        ))
        #expect(!SearchRunReconciliation.fullCancellationKeepsSearchActive(
            hasPendingPreview: false,
            tokenCancelled: false
        ))
        #expect(SearchRunReconciliation.previewApplicationCompletesSearch(fullSearchAlreadyFinished: true))
        #expect(!SearchRunReconciliation.previewApplicationCompletesSearch(fullSearchAlreadyFinished: false))
    }

    @Test("search preview scheduling includes relevance sort")
    func searchPreviewSchedulingIncludesRelevanceSort() {
        #expect(SearchPreviewScheduling.skipReason(
            appSearchActive: false,
            trimmedQuery: "test",
            sortColumn: .relevance,
            signatureAlreadyDisplayed: false
        ) == nil)
        #expect(SearchPreviewScheduling.skipReason(
            appSearchActive: false,
            trimmedQuery: "test",
            sortColumn: .name,
            signatureAlreadyDisplayed: false
        ) == nil)
        #expect(SearchPreviewScheduling.skipReason(
            appSearchActive: false,
            trimmedQuery: "test",
            sortColumn: .modified,
            signatureAlreadyDisplayed: false
        ) == nil)
        #expect(SearchPreviewScheduling.skipReason(
            appSearchActive: false,
            trimmedQuery: "test",
            sortColumn: .path,
            signatureAlreadyDisplayed: false
        ) == "unsupportedSort")
    }

    @Test("search run reconciliation rejects stale responses")
    func searchRunReconciliationRejectsStaleResponses() {
        #expect(SearchRunReconciliation.canApplyResponse(generationMatches: true, tokenMatches: true))
        #expect(!SearchRunReconciliation.canApplyResponse(generationMatches: false, tokenMatches: true))
        #expect(!SearchRunReconciliation.canApplyResponse(generationMatches: true, tokenMatches: false))
        #expect(SearchRunReconciliation.shouldRejectFinalEmptyResponse(
            existingResultCount: 25,
            displayedMatchesResponseSignature: true,
            responseResultCount: 0,
            responseTotalMatches: 0,
            responseSnapshotRevision: 3,
            currentSnapshotRevision: 4
        ))
        #expect(!SearchRunReconciliation.shouldRejectFinalEmptyResponse(
            existingResultCount: 25,
            displayedMatchesResponseSignature: true,
            responseResultCount: 0,
            responseTotalMatches: 0,
            responseSnapshotRevision: 4,
            currentSnapshotRevision: 4
        ))
        #expect(!SearchRunReconciliation.shouldRejectFinalEmptyResponse(
            existingResultCount: 0,
            displayedMatchesResponseSignature: true,
            responseResultCount: 0,
            responseTotalMatches: 0,
            responseSnapshotRevision: 3,
            currentSnapshotRevision: 4
        ))
        #expect(!SearchRunReconciliation.shouldRejectFinalEmptyResponse(
            existingResultCount: 25,
            displayedMatchesResponseSignature: false,
            responseResultCount: 0,
            responseTotalMatches: 0,
            responseSnapshotRevision: 3,
            currentSnapshotRevision: 4
        ))
        #expect(!SearchRunReconciliation.shouldRetryStaleFinalResponse(
            usesIndexedCandidates: true,
            responseSnapshotRevision: 3,
            currentSnapshotRevision: 4,
            signatureStillScheduled: true,
            responseResultCount: 25,
            responseTotalMatches: 1_000,
            isIndexing: true
        ))
        #expect(SearchRunReconciliation.shouldRetryStaleFinalResponse(
            usesIndexedCandidates: true,
            responseSnapshotRevision: 3,
            currentSnapshotRevision: 4,
            signatureStillScheduled: true,
            responseResultCount: 25,
            responseTotalMatches: 1_000,
            isIndexing: false
        ))
        #expect(SearchRunReconciliation.shouldRetryStaleFinalResponse(
            usesIndexedCandidates: true,
            responseSnapshotRevision: 3,
            currentSnapshotRevision: 4,
            signatureStillScheduled: true,
            responseResultCount: 0,
            responseTotalMatches: 0,
            isIndexing: true
        ))
        #expect(!SearchRunReconciliation.shouldRetryStaleFinalResponse(
            usesIndexedCandidates: false,
            responseSnapshotRevision: 3,
            currentSnapshotRevision: 4,
            signatureStillScheduled: true,
            responseResultCount: 25,
            responseTotalMatches: 1_000,
            isIndexing: false
        ))
    }

    @Test("foreground reconcile still presents as important reconcile")
    func foregroundReconcileStillPresentsAsImportantReconcile() {
        let now = Date(timeIntervalSince1970: 1_000)
        let stats = IndexStats(
            indexedCount: 10,
            isIndexing: true,
            isReconciling: true,
            phase: .scanning,
            discoveredCount: 4,
            searchableCount: 10,
            status: "Reconciling changed folders",
            lastUpdated: now,
            activeOperationStartedAt: now,
            activityPresentation: .foreground
        )

        let status = SearchWindowPresentation.indexStatusText(
            indexedRootsIsEmpty: false,
            fseventCatchUpStartedAt: nil,
            stats: stats,
            now: now
        )

        #expect(status.contains("Reconciling"))
        #expect(SearchWindowPresentation.isImportantMascotOperation(stats))
        #expect(SearchWindowPresentation.persistentMascotAnimation(stats: stats, hasActiveSearch: false) == .indexing)
        #expect(SearchWindowPresentation.persistentMascotAnimation(
            stats: stats,
            hasActiveSearch: true,
            isRefiningSearchResults: true
        ) == .indexing)
    }

    @MainActor
    private func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        let current = (view as? NSButton).map { [$0] } ?? []
        return view.subviews.reduce(current) { partial, subview in
            partial + buttons(in: subview)
        }
    }

    @MainActor
    private func textFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        let current = (view as? NSTextField).map { [$0] } ?? []
        return view.subviews.reduce(current) { partial, subview in
            partial + textFields(in: subview)
        }
    }

    @MainActor
    private func mascotFooterFrame() -> NSRect {
        NSRect(
            x: ExpandedMascotLayout.visibleLeadingInset,
            y: 8,
            width: OperationMascotCoordinator.statusDisplaySize,
            height: OperationMascotCoordinator.displayHeight(for: OperationMascotCoordinator.statusDisplaySize)
        )
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
