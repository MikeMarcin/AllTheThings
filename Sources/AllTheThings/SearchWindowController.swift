import AppKit
import ATTCore
import QuartzCore
import UniformTypeIdentifiers

enum AppRuntimeStatusFormatter {
    static let transientReadyStatusDisplayDuration: TimeInterval = 5

    static func windowTitle(version: String?, build: String?) -> String {
        "AllTheThings"
    }

    static func footerVersion(version: String?, build: String?) -> String {
        switch (version, build) {
        case let (version?, _) where !version.isEmpty:
            return version
        case let (_, build?) where !build.isEmpty:
            return build
        default:
            return ""
        }
    }

    static func operationElapsed(_ elapsed: TimeInterval) -> String {
        let totalSeconds = max(Int(elapsed.rounded()), 0)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return "\(hours)h \(String(format: "%02dm", minutes))"
        }
        if minutes > 0 {
            return "\(minutes)m \(String(format: "%02ds", seconds))"
        }
        return "\(seconds)s"
    }

    static func catchUpStatus(elapsed: TimeInterval) -> String {
        "Catching up changes • \(operationElapsed(elapsed))"
    }

    static func readyStatus(status: String, lastUpdated: Date, now: Date = Date()) -> String {
        guard isTransientReadyStatus(status) else {
            return "Ready • \(status)"
        }

        let statusAge = max(now.timeIntervalSince(lastUpdated), 0)
        return statusAge <= transientReadyStatusDisplayDuration ? "Ready • \(status)" : "Ready"
    }

    private static func isTransientReadyStatus(_ status: String) -> Bool {
        status == "No file changes"
            || (status.hasPrefix("Updated ")
                && (status.hasSuffix(" changed path") || status.hasSuffix(" changed paths")))
    }
}

enum SearchWindowPresentation {
    struct IndexStatusFooterText: Equatable {
        let operationText: String
        let detailText: String

        var combinedText: String {
            if operationText.isEmpty {
                return detailText
            }
            if detailText.isEmpty {
                return operationText
            }
            return "\(operationText) • \(detailText)"
        }
    }

    struct DetailedFooterText: Equatable {
        let centerText: String
        let operationText: String
        let rightText: String
    }

    nonisolated static func isImportantMascotOperation(_ stats: IndexStats) -> Bool {
        guard !stats.isUpdating else { return false }
        guard stats.activityPresentation != .backgroundCatchUp else { return false }
        return isImportantMascotOperation(stats.phase)
    }

    nonisolated static func persistentMascotAnimation(
        stats: IndexStats,
        hasActiveSearch: Bool,
        isRefiningSearchResults: Bool = false
    ) -> OperationMascotAnimation {
        if stats.activityPresentation == .backgroundCatchUp {
            return hasActiveSearch ? (isRefiningSearchResults ? .searchRefining : .searching) : .idle
        }

        if stats.isUpdating {
            return .updating
        }

        switch stats.phase {
        case .loading, .scanning:
            return .indexing
        case .optimizing, .saving:
            return .optimizing
        case .idle, .ready, .failed:
            break
        }

        return hasActiveSearch ? (isRefiningSearchResults ? .searchRefining : .searching) : .idle
    }

    nonisolated static func indexStatusText(
        indexedRootsIsEmpty: Bool,
        fseventCatchUpStartedAt: Date?,
        stats indexStats: IndexStats,
        now: Date = Date()
    ) -> String {
        indexStatusFooterText(
            indexedRootsIsEmpty: indexedRootsIsEmpty,
            fseventCatchUpStartedAt: fseventCatchUpStartedAt,
            stats: indexStats,
            now: now
        ).combinedText
    }

    nonisolated static func indexStatusFooterText(
        indexedRootsIsEmpty: Bool,
        fseventCatchUpStartedAt: Date?,
        stats indexStats: IndexStats,
        now: Date = Date()
    ) -> IndexStatusFooterText {
        if indexedRootsIsEmpty {
            return IndexStatusFooterText(operationText: "No folders", detailText: "")
        }

        if let fseventCatchUpStartedAt {
            let elapsed = max(now.timeIntervalSince(fseventCatchUpStartedAt), 0)
            return IndexStatusFooterText(
                operationText: detailText(["Catching up changes", AppRuntimeStatusFormatter.operationElapsed(elapsed)]),
                detailText: searchableDetail(stats: indexStats)
            )
        }

        switch indexStats.phase {
        case .idle:
            return IndexStatusFooterText(operationText: indexStats.status, detailText: "")
        case .loading:
            return IndexStatusFooterText(operationText: "Loading", detailText: indexStats.status)
        case .scanning:
            let searchableDetail = searchableDetail(stats: indexStats)
            if indexStats.activityPresentation == .backgroundCatchUp {
                return IndexStatusFooterText(
                    operationText: operationText(indexStats.status, stats: indexStats, now: now),
                    detailText: searchableDetail
                )
            }
            if indexStats.isUpdating {
                return IndexStatusFooterText(
                    operationText: operationText(indexStats.status, stats: indexStats, now: now),
                    detailText: searchableDetail
                )
            }
            if indexStats.status == "Reconciling changed folders" {
                return IndexStatusFooterText(
                    operationText: operationText(indexStats.status, stats: indexStats, now: now),
                    detailText: searchableDetail
                )
            }
            let verb = indexStats.isReconciling ? "Reconciling" : "Indexing"
            return IndexStatusFooterText(
                operationText: operationText(
                    "\(verb) \(indexStats.discoveredCount.formatted()) discovered",
                    stats: indexStats,
                    now: now
                ),
                detailText: searchableDetail
            )
        case .optimizing:
            let detail = searchableDetail(stats: indexStats)
            if indexStats.activityPresentation == .backgroundCatchUp {
                return IndexStatusFooterText(
                    operationText: operationText("Catching up changes", stats: indexStats, now: now),
                    detailText: detail
                )
            }
            return IndexStatusFooterText(
                operationText: operationText(indexStats.status, stats: indexStats, now: now),
                detailText: detail
            )
        case .saving:
            let detail = searchableDetail(stats: indexStats)
            if indexStats.activityPresentation == .backgroundCatchUp {
                return IndexStatusFooterText(
                    operationText: operationText("Catching up changes", stats: indexStats, now: now),
                    detailText: detail
                )
            }
            return IndexStatusFooterText(
                operationText: operationText("Saving index", stats: indexStats, now: now),
                detailText: detail
            )
        case .ready:
            let status = AppRuntimeStatusFormatter.readyStatus(status: indexStats.status, lastUpdated: indexStats.lastUpdated)
            let pieces = status.components(separatedBy: " • ")
            if pieces.count >= 2 {
                return IndexStatusFooterText(
                    operationText: pieces[0],
                    detailText: pieces.dropFirst().joined(separator: " • ")
                )
            }
            return IndexStatusFooterText(operationText: status, detailText: "")
        case .failed:
            return IndexStatusFooterText(operationText: indexStats.status, detailText: "")
        }
    }

    nonisolated private static func isImportantMascotOperation(_ phase: IndexPhase) -> Bool {
        switch phase {
        case .scanning, .optimizing, .saving:
            return true
        case .idle, .loading, .ready, .failed:
            return false
        }
    }

    nonisolated private static func operationText(_ text: String, stats indexStats: IndexStats, now: Date) -> String {
        detailText([
            text,
            operationElapsedText(startedAt: indexStats.activeOperationStartedAt, now: now)
        ])
    }

    nonisolated private static func searchableDetail(stats indexStats: IndexStats) -> String {
        "\(indexStats.searchableCount.formatted()) searchable"
    }

    nonisolated private static func operationElapsedText(startedAt: Date?, now: Date = Date()) -> String? {
        guard let startedAt else { return nil }
        let elapsed = max(now.timeIntervalSince(startedAt), 0)
        return AppRuntimeStatusFormatter.operationElapsed(elapsed)
    }

    nonisolated static func detailText(_ segments: [String?]) -> String {
        segments.compactMap { segment in
            guard let segment, !segment.isEmpty else { return nil }
            return segment
        }.joined(separator: " • ")
    }

    nonisolated static func shouldShowSearchElapsedText(
        displayedSearchSignatureIsSet: Bool,
        queryElapsed: TimeInterval,
        initialQueryElapsed: TimeInterval?,
        isRefiningSearchResults: Bool,
        hasFinalSearchTiming: Bool
    ) -> Bool {
        displayedSearchSignatureIsSet
            && (queryElapsed > 0
                || initialQueryElapsed != nil
                || isRefiningSearchResults
                || hasFinalSearchTiming)
    }

    nonisolated static func searchElapsedText(
        queryElapsed: TimeInterval,
        initialQueryElapsed: TimeInterval?,
        isRefiningSearchResults: Bool,
        hasFinalSearchTiming: Bool
    ) -> String {
        let finalMilliseconds = Int((queryElapsed * 1_000).rounded())
        guard let initialQueryElapsed else {
            return "\(finalMilliseconds) ms"
        }

        let initialMilliseconds = Int((initialQueryElapsed * 1_000).rounded())
        if isRefiningSearchResults {
            return "\(initialMilliseconds) ms (refining)"
        }

        guard hasFinalSearchTiming else {
            return "\(initialMilliseconds) ms"
        }

        return "\(initialMilliseconds) ms (\(finalMilliseconds) ms)"
    }

    nonisolated static func operationStatusText(operationText: String, searchElapsedText: String?) -> String {
        detailText([operationText, searchElapsedText])
    }

    nonisolated static func detailedFooterText(
        shownText: String,
        operationText: String,
        detailText: String,
        appSearchScopeText: String?,
        memoryStatusText: String,
        searchElapsedText: String?
    ) -> DetailedFooterText {
        DetailedFooterText(
            centerText: shownText,
            operationText: operationStatusText(
                operationText: operationText,
                searchElapsedText: searchElapsedText
            ),
            rightText: Self.detailText([
                detailText,
                appSearchScopeText,
                memoryStatusText
            ])
        )
    }
}

enum SearchRunReconciliation {
    nonisolated static func canApplyResponse(generationMatches: Bool, tokenMatches: Bool) -> Bool {
        generationMatches && tokenMatches
    }

    nonisolated static func fullCancellationKeepsSearchActive(
        hasPendingPreview: Bool,
        tokenCancelled: Bool
    ) -> Bool {
        hasPendingPreview && !tokenCancelled
    }

    nonisolated static func previewApplicationCompletesSearch(fullSearchAlreadyFinished: Bool) -> Bool {
        fullSearchAlreadyFinished
    }

    nonisolated static func shouldRejectFinalEmptyResponse(
        existingResultCount: Int,
        displayedMatchesResponseSignature: Bool,
        responseResultCount: Int,
        responseTotalMatches: Int,
        responseSnapshotRevision: UInt64?,
        currentSnapshotRevision: UInt64
    ) -> Bool {
        guard
            existingResultCount > 0,
            displayedMatchesResponseSignature,
            responseResultCount == 0,
            responseTotalMatches == 0,
            let responseSnapshotRevision,
            responseSnapshotRevision < currentSnapshotRevision
        else {
            return false
        }

        return true
    }
}

enum SearchPreviewScheduling {
    nonisolated static func skipReason(
        appSearchActive: Bool,
        trimmedQuery: String,
        sortColumn: SortColumn,
        signatureAlreadyDisplayed: Bool
    ) -> String? {
        if appSearchActive {
            return "applicationSearch"
        }
        if trimmedQuery.isEmpty {
            return "emptyQuery"
        }
        if sortColumn != .relevance && sortColumn != .name && sortColumn != .modified {
            return "unsupportedSort"
        }
        if signatureAlreadyDisplayed {
            return "alreadyDisplayed"
        }
        return nil
    }
}

@MainActor
enum ExpandedMascotLayout {
    struct Target: Equatable {
        let anchorX: CGFloat
        let bottomConstraintConstant: CGFloat
        let displaySize: CGFloat
    }

    static let visibleLeadingInset: CGFloat = 0
    static let operationVisibleContentLeadingInset: CGFloat = 12
    static let expandedFooterLift: CGFloat = OperationMascotCoordinator.footerSlotHeight
    static let autoExpandDelay: TimeInterval = 0.75

    static func anchorX(for displaySize: CGFloat) -> CGFloat {
        visibleLeadingInset + (displaySize / 2) - contentLeadingInset(for: displaySize)
    }

    static func contentLeadingInset(for displaySize: CGFloat) -> CGFloat {
        operationVisibleContentLeadingInset * displaySize / OperationMascotCoordinator.expandedDisplaySize
    }

    static func collapsedTarget(footerFrame: NSRect) -> Target {
        Target(
            anchorX: footerFrame.midX,
            bottomConstraintConstant: 0,
            displaySize: OperationMascotCoordinator.statusDisplaySize
        )
    }

    static func expandedTarget(displaySize: CGFloat = OperationMascotCoordinator.expandedDisplaySize) -> Target {
        Target(
            anchorX: anchorX(for: displaySize),
            bottomConstraintConstant: -expandedFooterLift,
            displaySize: displaySize
        )
    }

    static func expandedFrame(
        footerFrame: NSRect,
        displaySize: CGFloat = OperationMascotCoordinator.expandedDisplaySize
    ) -> NSRect {
        let target = expandedTarget(displaySize: displaySize)
        return NSRect(
            x: target.anchorX - (displaySize / 2),
            y: footerFrame.minY - target.bottomConstraintConstant,
            width: displaySize,
            height: OperationMascotCoordinator.displayHeight(for: displaySize)
        )
    }

    static func visibleContentLeadingX(
        footerFrame: NSRect,
        displaySize: CGFloat = OperationMascotCoordinator.expandedDisplaySize
    ) -> CGFloat {
        expandedFrame(footerFrame: footerFrame, displaySize: displaySize).minX
            + contentLeadingInset(for: displaySize)
    }
}

final class SearchWindowController: NSWindowController {
    private enum WindowLayout {
        static let preferredContentSize = NSSize(width: 1_180, height: 720)
        static let minimumContentSize = NSSize(width: 920, height: 540)
        static let visibleFrameInset: CGFloat = 64
    }

    init(index: FileIndex) {
        let viewController = SearchViewController(index: index)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.startupContentSize()),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = Self.windowTitle()
        window.titlebarAppearsTransparent = true
        window.canHide = true
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.isRestorable = false
        window.contentMinSize = WindowLayout.minimumContentSize
        window.contentViewController = viewController
        window.center()
        super.init(window: window)
        viewController.installTitlebarActions(in: window)
    }

    private static func windowTitle() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return AppRuntimeStatusFormatter.windowTitle(version: version, build: build)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    func focusSearchField(selectText: Bool) {
        guard let viewController = window?.contentViewController as? SearchViewController else { return }
        viewController.focusSearchField(selectText: selectText)
    }

    @MainActor
    func focusSearchField(prefill text: String) {
        guard let viewController = window?.contentViewController as? SearchViewController else { return }
        viewController.focusSearchField(prefill: text)
    }

    @MainActor
    func updateSearchQuery(_ text: String) {
        guard let viewController = window?.contentViewController as? SearchViewController else { return }
        viewController.updateSearchQuery(text)
    }

    @MainActor
    func suppressNextSearchFieldFocusOnAppear() {
        guard let viewController = window?.contentViewController as? SearchViewController else { return }
        viewController.suppressNextSearchFieldFocusOnAppear()
    }

    @MainActor
    func reindexConfiguredRootsFromSettings() {
        guard let viewController = window?.contentViewController as? SearchViewController else { return }
        viewController.reindexConfiguredRootsFromSettings()
    }

    nonisolated static func zeroRowRootRecoveryPaths(
        snapshotRoots: [IndexRootInsight],
        configuredRootPaths: [String],
        accessStatus: (String) -> InsightsRootAccessStatus = { InsightsRootAccessStatus.status(for: $0) }
    ) -> [String] {
        zeroRowRootRecoveryCandidatePaths(
            snapshotRoots: snapshotRoots,
            configuredRootPaths: configuredRootPaths
        )
        .filter { accessStatus($0) == .readable }
    }

    nonisolated static func zeroRowRootRecoveryCandidatePaths(
        snapshotRoots: [IndexRootInsight],
        configuredRootPaths: [String]
    ) -> [String] {
        guard !configuredRootPaths.isEmpty else { return [] }

        let roots = InsightsRootDisplay.roots(
            snapshotRoots: snapshotRoots,
            configuredRootPaths: configuredRootPaths
        )
        var rootsByPath: [String: IndexRootInsight] = [:]
        for root in roots {
            rootsByPath[root.path] = root
        }
        var seen = Set<String>()
        var paths: [String] = []

        for path in configuredRootPaths where seen.insert(path).inserted {
            guard
                let root = rootsByPath[path],
                InsightsRootDisplay.hasNoIndexedRows(root)
            else {
                continue
            }
            paths.append(path)
        }

        return paths
    }

    private static func startupContentSize() -> NSSize {
        guard let visibleFrame = NSScreen.main?.visibleFrame else {
            return WindowLayout.preferredContentSize
        }

        let availableWidth = max(WindowLayout.minimumContentSize.width, visibleFrame.width - WindowLayout.visibleFrameInset)
        let availableHeight = max(WindowLayout.minimumContentSize.height, visibleFrame.height - WindowLayout.visibleFrameInset)

        return NSSize(
            width: min(WindowLayout.preferredContentSize.width, availableWidth),
            height: min(WindowLayout.preferredContentSize.height, availableHeight)
        )
    }
}

private final class PassthroughTitlebarLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class SearchViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate, NSToolbarDelegate, NSToolbarItemValidation, NSMenuItemValidation {
    private enum Palette {
        static let searchBandBackground = NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(calibratedRed: 30.0 / 255.0, green: 30.0 / 255.0, blue: 30.0 / 255.0, alpha: 1)
            }

            return .windowBackgroundColor
        }
    }

    private enum Column: String, CaseIterable {
        case match
        case name
        case path
        case modified
        case size
        case created
        case ext
        case kind
        case volume
        case root

        var title: String {
            switch self {
            case .match: "Match"
            case .name: "Name"
            case .path: "Path"
            case .modified: "Modified"
            case .size: "Size"
            case .created: "Created"
            case .ext: "Ext"
            case .kind: "Kind"
            case .volume: "Volume"
            case .root: "Root"
            }
        }

        var width: CGFloat {
            switch self {
            case .match: 40
            case .name: 220
            case .path: 380
            case .modified: 112
            case .size: 72
            case .created: 112
            case .ext: 48
            case .kind: 52
            case .volume: 80
            case .root: 160
            }
        }

        var sortColumn: SortColumn {
            switch self {
            case .match: .relevance
            case .name: .name
            case .path: .path
            case .modified: .modified
            case .size: .size
            case .created: .created
            case .ext: .fileExtension
            case .kind: .kind
            case .volume: .volume
            case .root: .root
            }
        }

        var menuTitle: String {
            switch self {
            case .match: "Match Quality"
            case .name: "Name"
            case .path: "Path"
            case .modified: "Date Modified"
            case .size: "Size"
            case .created: "Date Created"
            case .ext: "Extension"
            case .kind: "Kind"
            case .volume: "Volume"
            case .root: "Indexed Root"
            }
        }

        static func column(for sortColumn: SortColumn) -> Column? {
            switch sortColumn {
            case .relevance:
                .match
            case .name:
                .name
            case .path:
                .path
            case .modified:
                .modified
            case .created:
                .created
            case .size:
                .size
            case .fileExtension:
                .ext
            case .kind:
                .kind
            case .volume:
                .volume
            case .root:
                .root
            }
        }
    }

    private enum TerminalService: CaseIterable {
        case ghosttyTab
        case ghosttyWindow
        case iTermTab
        case iTermWindow

        var title: String {
            switch self {
            case .ghosttyTab: "New Ghostty Tab Here"
            case .ghosttyWindow: "New Ghostty Window Here"
            case .iTermTab: "New iTerm2 Tab Here"
            case .iTermWindow: "New iTerm2 Window Here"
            }
        }

        var bundleIdentifiers: [String] {
            switch self {
            case .ghosttyTab, .ghosttyWindow:
                ["com.mitchellh.ghostty"]
            case .iTermTab, .iTermWindow:
                ["com.googlecode.iterm2"]
            }
        }

        var fallbackAppNames: [String] {
            switch self {
            case .ghosttyTab, .ghosttyWindow:
                ["Ghostty"]
            case .iTermTab, .iTermWindow:
                ["iTerm", "iTerm2"]
            }
        }
    }

    private struct SearchSignature: Equatable {
        let query: String
        let sort: SortSpec
        let includeHidden: Bool
    }

    private struct ExplanationCacheKey: Hashable {
        let query: String
        let recordID: UInt64
    }

    private enum SearchScheduling {
        static let unoptimizedIndexingSearchBudget: TimeInterval = 0.75
    }

    private final class SearchBudgetTimeout: @unchecked Sendable {
        private let lock = NSLock()
        private var timedOut = false

        var didTimeOut: Bool {
            lock.withLock {
                timedOut
            }
        }

        func markTimedOut() {
            lock.withLock {
                timedOut = true
            }
        }
    }

    private enum MascotFlightPlayback {
        case animation(OperationMascotAnimation)
        case standalone(OperationMascotStandaloneClip)

        var frameCount: Int {
            switch self {
            case let .animation(animation): animation.frameCount
            case let .standalone(clip): clip.frameCount
            }
        }

        var framesPerSecond: Double {
            switch self {
            case let .animation(animation): animation.framesPerSecond
            case let .standalone(clip): clip.framesPerSecond
            }
        }

        var loops: Bool {
            switch self {
            case let .animation(animation): animation.loops
            case let .standalone(clip): clip.loops
            }
        }

        var startsFromFirstFrame: Bool {
            switch self {
            case .animation: false
            case .standalone: true
            }
        }

        @MainActor
        func frame(from spriteSheet: MascotSpriteSheet, index: Int) -> NSImage? {
            switch self {
            case let .animation(animation):
                return spriteSheet.frame(for: animation, index: index)
            case let .standalone(clip):
                return spriteSheet.frame(for: clip, index: index)
            }
        }
    }

    private struct MascotPresentationContext {
        let setupMascotVisible: Bool
        let mascotFlightVisible: Bool
        let loadingOverlayVisible: Bool

        var transientMascotOwnsPlacement: Bool {
            setupMascotVisible || mascotFlightVisible
        }

        var loadingMascotVisible: Bool {
            loadingOverlayVisible && !transientMascotOwnsPlacement
        }
    }

    @MainActor
    private final class ExpandedMascotPresentationController {
        private let rootView: NSView
        private let footerSlotView: ClickableMascotView
        private let footerImageView: NSImageView
        private let expandedView: ClickableMascotView
        private let expandedImageView: NSImageView
        private let animationCoordinator: OperationMascotCoordinator
        private let centerXConstraint: NSLayoutConstraint
        private let imageBottomConstraint: NSLayoutConstraint
        private let updateHostPlacement: () -> Void

        private(set) var isExpanded = false
        private var isTransitionInProgress = false
        private var deferredPersistentAnimation: OperationMascotAnimation?
        private var deferredTransientAnimation: OperationMascotAnimation?
        private var transitionID: UInt64 = 0

        var ownsMascotPlacement: Bool {
            isExpanded || isTransitionInProgress
        }

        init(
            rootView: NSView,
            footerSlotView: ClickableMascotView,
            footerImageView: NSImageView,
            expandedView: ClickableMascotView,
            expandedImageView: NSImageView,
            animationCoordinator: OperationMascotCoordinator,
            centerXConstraint: NSLayoutConstraint,
            imageBottomConstraint: NSLayoutConstraint,
            updateHostPlacement: @escaping () -> Void
        ) {
            self.rootView = rootView
            self.footerSlotView = footerSlotView
            self.footerImageView = footerImageView
            self.expandedView = expandedView
            self.expandedImageView = expandedImageView
            self.animationCoordinator = animationCoordinator
            self.centerXConstraint = centerXConstraint
            self.imageBottomConstraint = imageBottomConstraint
            self.updateHostPlacement = updateHostPlacement
        }

        func setPersistentAnimation(_ animation: OperationMascotAnimation) {
            guard !isTransitionInProgress else {
                deferredPersistentAnimation = animation
                return
            }
            animationCoordinator.setPersistentAnimation(animation)
        }

        func playTransient(_ animation: OperationMascotAnimation) {
            guard !isTransitionInProgress else {
                deferredTransientAnimation = animation
                return
            }
            animationCoordinator.playTransient(animation)
        }

        func setPlaybackSuspended(_ suspended: Bool) {
            animationCoordinator.setPlaybackSuspended(suspended)
        }

        func placementTargetFrame() -> NSRect {
            rootView.layoutSubtreeIfNeeded()
            if ownsMascotPlacement {
                return expandedImageView.convert(expandedImageView.bounds, to: rootView)
            }

            return footerImageView.convert(footerImageView.bounds, to: rootView)
        }

        func expandedTargetFrame() -> NSRect {
            ExpandedMascotLayout.expandedFrame(footerFrame: currentFooterFrame())
        }

        func setExpanded(_ visible: Bool, animated: Bool, context: MascotPresentationContext) {
            guard isExpanded != visible else {
                updatePlacement(context: context)
                return
            }

            isExpanded = visible
            transitionID &+= 1
            let currentTransitionID = transitionID
            updateTooltips(expanded: visible)

            let footerFrame = currentFooterFrame()
            let collapsedTarget = ExpandedMascotLayout.collapsedTarget(footerFrame: footerFrame)
            let expandedTarget = ExpandedMascotLayout.expandedTarget()
            let target = visible ? expandedTarget : collapsedTarget
            let shouldTween = shouldTweenTransition(requested: animated)

            if visible && context.loadingOverlayVisible {
                isTransitionInProgress = false
                apply(target)
                animationCoordinator.setDisplaySize(target.displaySize)
                updatePlacement(context: context)
                return
            }

            if visible {
                apply(collapsedTarget)
                animationCoordinator.setDisplaySize(collapsedTarget.displaySize)
                expandedView.isHidden = false
                footerImageView.isHidden = true
                rootView.layoutSubtreeIfNeeded()
            }

            guard shouldTween else {
                isTransitionInProgress = false
                apply(target)
                animationCoordinator.setDisplaySize(target.displaySize)
                updatePlacement(context: context)
                return
            }

            if !visible {
                footerImageView.isHidden = true
                expandedView.isHidden = false
            }

            isTransitionInProgress = true
            animationCoordinator.setScaleTransitionActive(true)
            NSAnimationContext.runAnimationGroup { animationContext in
                animationContext.duration = 0.22
                animationContext.allowsImplicitAnimation = true
                self.apply(target)
                self.animationCoordinator.setDisplaySize(target.displaySize)
                self.rootView.animator().layoutSubtreeIfNeeded()
            } completionHandler: {
                guard self.transitionID == currentTransitionID else { return }
                self.isTransitionInProgress = false
                self.finishScaleTransition()
                if !visible {
                    let resetTarget = ExpandedMascotLayout.collapsedTarget(footerFrame: self.currentFooterFrame())
                    self.updateHostPlacement()
                    self.apply(resetTarget)
                    self.animationCoordinator.setDisplaySize(resetTarget.displaySize)
                    return
                }
                self.updateHostPlacement()
            }
        }

        func updatePlacement(context: MascotPresentationContext) {
            let expandedMascotVisible = ownsMascotPlacement
            expandedView.isHidden = context.transientMascotOwnsPlacement || context.loadingMascotVisible || !expandedMascotVisible
            footerImageView.isHidden = context.transientMascotOwnsPlacement || context.loadingMascotVisible || expandedMascotVisible
        }

        private func updateTooltips(expanded: Bool) {
            let tooltip = expanded ? "Shrink Nib" : "Grow Nib"
            expandedView.toolTip = tooltip
            footerSlotView.toolTip = tooltip
            footerImageView.toolTip = tooltip
            expandedView.accessibilityText = tooltip
            footerSlotView.accessibilityText = tooltip
        }

        private func currentFooterFrame() -> NSRect {
            rootView.layoutSubtreeIfNeeded()
            return footerImageView.convert(footerImageView.bounds, to: rootView)
        }

        private func apply(_ target: ExpandedMascotLayout.Target) {
            centerXConstraint.constant = target.anchorX
            imageBottomConstraint.constant = target.bottomConstraintConstant
        }

        private func shouldTweenTransition(requested animated: Bool) -> Bool {
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                return false
            }

            return animated || rootView.window != nil
        }

        private func finishScaleTransition() {
            animationCoordinator.setScaleTransitionActive(false)

            if let deferredPersistentAnimation {
                self.deferredPersistentAnimation = nil
                animationCoordinator.setPersistentAnimation(deferredPersistentAnimation)
            }

            if let deferredTransientAnimation {
                self.deferredTransientAnimation = nil
                animationCoordinator.playTransient(deferredTransientAnimation)
            }
        }
    }

    private let index: FileIndex
    private let fseventCursorStore = FSEventCursorStore.default
    private lazy var watcher = FileSystemWatcher(cursorStore: fseventCursorStore)
    private lazy var fseventReconciler = FSEventReconciliationCoordinator(cursorStore: fseventCursorStore)
    private let searchQueue = DispatchQueue(label: "att.search", qos: .userInitiated)
    private let searchPreviewQueue = DispatchQueue(label: "att.search.preview", qos: .userInteractive, attributes: .concurrent)
    private let explanationQueue = DispatchQueue(label: "att.search.explain", qos: .utility)
    private let applicationSearchCatalog = ApplicationSearchCatalog()
    private let defaults = UserDefaults.standard

    private let searchField = NSSearchField()
    private let setupSuggestionPanel = SetupSuggestionPanelView()
    private let tableView = FileTableView()
    private let headerMenu = NSMenu()
    private let scrollView = NSScrollView()
    private let mascotSlotView = ClickableMascotView()
    private let mascotImageView = NSImageView()
    private let expandedMascotView = ClickableMascotView()
    private let expandedMascotImageView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let operationStatusLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private var titlebarToolbar: NSToolbar?
    private weak var centeredTitleLabel: NSTextField?
    private let loadingOverlay = ThemedBackgroundView(backgroundColor: NSColor.windowBackgroundColor.withAlphaComponent(0.92))
    private let loadingMascotImageView = NSImageView()
    private let loadingLabel = NSTextField(labelWithString: "Loading file list...")
    private let indexingSetupOverlay = IndexingSetupOverlayView()
    private let mascotFlightImageView = NSImageView()

    private var results: [SearchResult] = []
    private var contextMenuTargetRow: Int?
    private var explanationCache: [ExplanationCacheKey: MatchExplanation] = [:]
    private var indexStats: IndexStats
    private var totalMatches = 0
    private var queryElapsed: TimeInterval = 0
    private var initialQueryElapsed: TimeInterval?
    private var isRefiningSearchResults = false
    private var hasFinalSearchTiming = false
    private var activeSearchStartedAt: Date?
    private nonisolated(unsafe) var searchStatusTimer: Timer?
    private var pendingSearchInputStartedAt: Date?
    private var queryGeneration: UInt64 = 0
    private var activeSearchToken: SearchCancellationToken?
    private var pendingPreviewSearchToken: SearchCancellationToken?
    private var activeSearchFullFinished = false
    private var activeSearchNeedsRetryAfterPreview = false
    private var explanationGeneration: UInt64 = 0
    private var activeExplanationToken = SearchCancellationToken()
    private var pendingExplanationKeys = Set<ExplanationCacheKey>()
    private var scheduledSearchSignature: SearchSignature?
    private var displayedSearchSignature: SearchSignature?
    private var statusPreviewSearchText: String?
    private var sortSpec: SortSpec
    private var visibleColumns: Set<Column>
    private var indexedRoots: [URL]
    private var rootDisplayNames: [String: String] = [:]
    private var pendingEventPaths = Set<String>()
    private var pendingRecursiveEventPaths = Set<String>()
    private var eventDebounce: DispatchWorkItem?
    private var activeFSEventReplay: FSEventHistoryReplayCancellable?
    private var activeFSEventReconciliationID: UUID?
    private var fseventCatchUpStartedAt: Date?
    private var pendingFSEventCatchUpRoots: [URL]?
    private var activeFSEventScopedCatchUpBaseline: (rootPaths: [String], eventID: UInt64)?
    private var queuedFSEventScopedCatchUpBaseline: (rootPaths: [String], eventID: UInt64)?
    private var memoryStatusTask: Task<Void, Never>?
    private var memoryStatusText = ProcessMemoryFormatter.label(for: ProcessMemorySampler.currentUsage())
    private var energyMode: EnergyMode = .interactive
    private var mascotCoordinator: OperationMascotCoordinator?
    private var expandedMascotPresenter: ExpandedMascotPresentationController?
    private var loadingMascotCoordinator: OperationMascotCoordinator?
    private var setupMascotCoordinator: StandaloneMascotCoordinator?
    private var mascotFlightPlayback: MascotFlightPlayback?
    private var mascotFlightFallbackImage: NSImage?
    private var mascotFlightFrameIndex = 0
    private var suppressesNextSearchFieldFocusOnAppear = false
    private nonisolated(unsafe) var mascotFlightFrameTimer: Timer?
    private var isMascotFlightInProgress = false
    private var isSetupMascotTuckInProgress = false
    private nonisolated(unsafe) var pendingMascotExpansion: DispatchWorkItem?
    private var loadingOverlaySawActiveLoad = false
    private var userExpandedMascot = false
    private var userCollapsedExpandedMascotDuringOperation = false
    private var isMascotPlaybackPaused = false
    private var wasImportantMascotOperationActive = false
    private var didRequestInitialSnapshotLoad = false
    private var didRequestInitialRebuild = false
    private var attemptedZeroRowRootRecoveryPaths = Set<String>()
    private var zeroRowRootRecoveryCandidatePaths: [String] = []
    private var zeroRowRootRecoveryCandidateSnapshotRevision: UInt64?
    private nonisolated(unsafe) var pendingZeroRowRootRecoveryWorkItem: DispatchWorkItem?
    private var highlightsSearchText: Bool
    private var showsHiddenFiles: Bool
    private var statusFooterMode: AppStatusFooterMode
    private var appFontFamilyName: String?
    private var appFontSize: CGFloat
    private var matchDetailsPopover: NSPopover?

    private enum DefaultsKey {
        static let sortColumn = "ATTSortColumn"
        static let sortAscending = "ATTSortAscending"
        static let visibleColumns = "ATTVisibleColumns"
        static let visibleColumnsSchema = "ATTVisibleColumnsSchema"
    }

    private enum SearchTitlebarToolbar {
        static let identifier = NSToolbar.Identifier("ATTSearchTitlebarToolbar")
        static let settings = NSToolbarItem.Identifier("ATTSearchTitlebarToolbar.settings")
        static let insights = NSToolbarItem.Identifier("ATTSearchTitlebarToolbar.insights")
        static let open = NSToolbarItem.Identifier("ATTSearchTitlebarToolbar.open")
        static let reveal = NSToolbarItem.Identifier("ATTSearchTitlebarToolbar.reveal")
        static let copy = NSToolbarItem.Identifier("ATTSearchTitlebarToolbar.copy")

        static let defaultItems: [NSToolbarItem.Identifier] = [
            .flexibleSpace,
            settings,
            insights,
            .space,
            open,
            reveal,
            copy
        ]

        static let allowedItems: [NSToolbarItem.Identifier] = [
            settings,
            insights,
            open,
            reveal,
            copy,
            .space,
            .flexibleSpace
        ]

        static let selectionItems: Set<NSToolbarItem.Identifier> = [
            open,
            reveal,
            copy
        ]
    }

    private enum EnergyMode {
        case interactive
        case background

        var watcherConfiguration: FileSystemWatcher.StreamConfiguration {
            switch self {
            case .interactive:
                return .interactive
            case .background:
                return .background
            }
        }

        var eventDebounceDelay: TimeInterval {
            switch self {
            case .interactive:
                return 0.05
            case .background:
                return 3.0
            }
        }

        var memoryStatusPollInterval: Duration {
            switch self {
            case .interactive:
                return .seconds(2)
            case .background:
                return .seconds(30)
            }
        }

        var suspendsMascotPlayback: Bool {
            self == .background
        }
    }

    private static let defaultSortSpec = SortSpec(column: .name, ascending: true)
    private static let defaultVisibleColumns = Set(Column.allCases.filter { $0 != .root })

    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d/yyyy HH:mm"
        return formatter
    }()

    private lazy var byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    init(index: FileIndex) {
        let defaults = UserDefaults.standard
        AppSettings.registerDefaults(defaults)
        let visibleColumns = Self.loadVisibleColumns(defaults: defaults)
        self.index = index
        self.indexStats = index.currentStats()
        self.visibleColumns = visibleColumns
        self.sortSpec = Self.normalizedSortSpec(Self.loadSortSpec(defaults: defaults), visibleColumns: visibleColumns)
        self.indexedRoots = AppSettings.indexedRoots(defaults: defaults)
        self.rootDisplayNames = Self.rootDisplayNames(for: self.indexedRoots.map { $0.standardizedFileURL.path })
        self.highlightsSearchText = defaults.bool(forKey: AppSettings.highlightSearchTextKey)
        self.showsHiddenFiles = defaults.bool(forKey: AppSettings.showHiddenFilesKey)
        self.statusFooterMode = AppSettings.statusFooterMode(defaults: defaults)
        self.appFontFamilyName = AppSettings.appFontFamilyName(defaults: defaults)
        self.appFontSize = AppSettings.appFontSize(defaults: defaults)
        super.init(nibName: nil, bundle: nil)
    }

    deinit {
        activeFSEventReplay?.cancel()
        searchStatusTimer?.invalidate()
        searchStatusTimer = nil
        memoryStatusTask?.cancel()
        activeExplanationToken.cancel()
        pendingMascotExpansion?.cancel()
        pendingZeroRowRootRecoveryWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = ThemedBackgroundView()
        rootView.appearanceDidChange = { [weak self] in
            self?.tableView.reloadData()
        }
        view = rootView
        buildInterface()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        index.onStatsChanged = { @MainActor @Sendable [weak self] stats in
            self?.handleStatsChanged(stats)
        }
        index.onBackgroundReconciliationRequested = { @MainActor @Sendable [weak self] roots in
            self?.runFSEventsBackedReconciliation(roots: roots)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange(_:)),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appFontDidChange(_:)),
            name: AppSettings.appFontDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(statusFooterModeDidChange(_:)),
            name: AppSettings.statusFooterModeDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(matchColorsDidChange(_:)),
            name: AppSettings.matchColorsDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(indexedRootsDidChange(_:)),
            name: AppSettings.indexedRootsDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appSearchRootsDidChange(_:)),
            name: AppSettings.appSearchRootsDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(exclusionPatternsDidChange(_:)),
            name: AppSettings.exclusionPatternsDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

        applyEnergyMode(Self.currentEnergyMode(), force: true)
        startWatchingIfNeeded()
        startMemoryStatusPolling()
        updateScanSnapshotPublishingPreference()
        updateLoadingOverlay()

        if indexStats.indexedCount > 0 {
            scheduleSearch(force: true)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if suppressesNextSearchFieldFocusOnAppear {
            suppressesNextSearchFieldFocusOnAppear = false
        } else {
            focusSearchField(selectText: false)
        }

        DispatchQueue.main.async { [weak self] in
            self?.startIndexingAfterFirstPaint()
        }
    }

    @MainActor
    func focusSearchField(selectText: Bool) {
        view.window?.makeFirstResponder(searchField)
        if selectText {
            searchField.selectText(nil)
        }
    }

    func focusSearchField(prefill text: String) {
        statusPreviewSearchText = nil
        view.window?.makeFirstResponder(searchField)
        searchField.stringValue = text
        if let editor = searchField.currentEditor() {
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
        markSearchInputStarted()
        scheduleSearch(force: true)
        updateSetupSuggestions()
    }

    func updateSearchQuery(_ text: String) {
        guard statusPreviewSearchText != text else { return }
        statusPreviewSearchText = text
        markSearchInputStarted()
        scheduleSearch()
        updateSetupSuggestions()
    }

    func suppressNextSearchFieldFocusOnAppear() {
        suppressesNextSearchFieldFocusOnAppear = true
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

        let result = results[row]
        let record = result.record

        if column == .match {
            let cell = makeMatchCell(for: tableColumn.identifier)
            configureMatchCell(cell, explanation: displayExplanation(for: result, schedulesAsyncExplanation: true))
            return cell
        }

        let cell = makeCell(for: tableColumn.identifier)
        let textField = cell.textField
        textField?.font = AppSettings.appFont(defaults: defaults)

        switch column {
        case .match:
            break
        case .name:
            textField?.attributedStringValue = highlightedText(
                record.name,
                field: .name,
                explanation: displayExplanation(for: result, schedulesAsyncExplanation: highlightsSearchText),
                baseAttributes: [
                    .foregroundColor: NSColor.labelColor,
                    .font: AppSettings.appFont(defaults: defaults, weight: .semibold)
                ]
            )
            textField?.lineBreakMode = .byTruncatingMiddle
        case .path:
            textField?.attributedStringValue = highlightedPath(
                record.directoryPath,
                explanation: displayExplanation(for: result, schedulesAsyncExplanation: highlightsSearchText)
            )
            textField?.textColor = .secondaryLabelColor
            textField?.lineBreakMode = .byTruncatingMiddle
        case .modified:
            textField?.stringValue = dateFormatter.string(from: record.modifiedDate)
            textField?.textColor = .labelColor
        case .size:
            textField?.stringValue = record.isDirectory
                ? (Self.isApplicationBundle(record) ? "App" : "Folder")
                : byteFormatter.string(fromByteCount: Int64(record.sizeBytes))
            textField?.textColor = .labelColor
            textField?.alignment = .right
        case .created:
            textField?.stringValue = record.createdDate.map(dateFormatter.string(from:)) ?? ""
            textField?.textColor = .labelColor
        case .ext:
            textField?.stringValue = record.fileExtension
            textField?.textColor = .secondaryLabelColor
        case .kind:
            textField?.stringValue = Self.kindName(for: record)
            textField?.textColor = .labelColor
        case .volume:
            textField?.stringValue = record.volumeName
            textField?.textColor = .secondaryLabelColor
        case .root:
            let rootPath = result.rootPath ?? ""
            textField?.stringValue = rootDisplayNames[rootPath] ?? Self.defaultRootDisplayName(for: rootPath)
            textField?.toolTip = rootPath.isEmpty ? nil : rootPath
            textField?.textColor = .secondaryLabelColor
            textField?.lineBreakMode = .byTruncatingMiddle
        }

        if column != .size {
            textField?.alignment = .left
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateActionButtons()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row >= 0, row < results.count else { return nil }
        return results[row].record.url as NSURL
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first else { return }
        sortSpec = sortSpec(for: descriptor)
        saveSortSpec()
        scheduleSearch(force: true)
    }

    func controlTextDidChange(_ obj: Notification) {
        markSearchInputStarted()
        scheduleSearch()
        updateSetupSuggestions()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control === searchField else { return false }

        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveResultSelection(delta: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveResultSelection(delta: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)), NSSelectorFromString("insertNewlineIgnoringFieldEditor:"):
            openSelectedOrFirstResult()
            return true
        default:
            return false
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === headerMenu {
            populateHeaderMenu(menu)
            return
        }

        menu.removeAllItems()
        let records = fileActionRecords()
        let hasSelection = !records.isEmpty
        let hasSingleSelection = records.count == 1

        menu.addItem(actionItem("Open", #selector(openSelected(_:)), enabled: hasSelection))
        menu.addItem(openWithMenuItem(enabled: hasSingleSelection))
        menu.addItem(.separator())
        menu.addItem(actionItem("Move to Trash", #selector(moveSelectedToTrash(_:)), enabled: hasSelection))
        menu.addItem(.separator())
        menu.addItem(actionItem("Get Info", #selector(getInfoSelected(_:)), enabled: hasSingleSelection))
        menu.addItem(actionItem("Rename", #selector(renameSelected(_:)), enabled: hasSingleSelection))
        menu.addItem(actionItem("Quick Look", #selector(quickLookSelected(_:)), enabled: hasSelection))
        menu.addItem(actionItem("Show Match Details", #selector(showMatchDetails(_:)), enabled: hasSingleSelection))
        menu.addItem(.separator())
        menu.addItem(actionItem("Copy", #selector(copy(_:)), enabled: hasSelection))
        menu.addItem(actionItem("Copy Path", #selector(copySelectedPath(_:)), enabled: hasSelection))
        menu.addItem(actionItem("Reveal in Finder", #selector(revealSelected(_:)), enabled: hasSelection))

        let terminalItems = terminalMenuItems(enabled: hasSingleSelection)
        if !terminalItems.isEmpty {
            menu.addItem(.separator())
            terminalItems.forEach { menu.addItem($0) }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === tableView.menu else { return }

        DispatchQueue.main.async { [weak self] in
            self?.setContextMenuTargetRow(nil)
        }
    }

    func installTitlebarActions(in window: NSWindow) {
        guard titlebarToolbar == nil else { return }

        let toolbar = NSToolbar(identifier: SearchTitlebarToolbar.identifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .regular
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false

        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.toolbar = toolbar
        titlebarToolbar = toolbar
        installCenteredTitle(in: window)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SearchTitlebarToolbar.defaultItems
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SearchTitlebarToolbar.allowedItems
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        titlebarToolbarItem(for: itemIdentifier)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        titlebarToolbarItemIsEnabled(item.itemIdentifier)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }

        let records = fileActionRecords()
        switch action {
        case #selector(openSelected(_:)),
             #selector(revealSelected(_:)),
             #selector(copy(_:)),
             #selector(copySelectedPath(_:)):
            return !records.isEmpty
        case #selector(quickLookSelected(_:)):
            return !records.isEmpty && !isSearchFieldEditing
        case #selector(moveSelectedToTrash(_:)):
            return !records.isEmpty && !isSearchFieldEditing
        case #selector(getInfoSelected(_:)),
             #selector(renameSelected(_:)):
            return records.count == 1
        case #selector(showMatchDetails(_:)):
            return fileActionRow() != nil
        case #selector(toggleExpandedMascot(_:)):
            menuItem.title = mascotIsExpanded ? "Hide Large Nib" : "Show Large Nib"
            menuItem.state = mascotIsExpanded ? .on : .off
            return true
        case #selector(toggleMascotPlaybackPaused(_:)):
            menuItem.title = isMascotPlaybackPaused ? "Resume Nib Animation" : "Pause Nib Animation"
            menuItem.state = isMascotPlaybackPaused ? .on : .off
            return true
        case #selector(resetMascotPosition(_:)):
            return mascotIsExpanded || userExpandedMascot || userCollapsedExpandedMascotDuringOperation
        default:
            return true
        }
    }

    private func titlebarToolbarItem(for itemIdentifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        let configuration: (label: String, symbol: String, tooltip: String, action: Selector)

        switch itemIdentifier {
        case SearchTitlebarToolbar.settings:
            configuration = ("Settings", "gearshape", "Open Settings", #selector(openSettings(_:)))
        case SearchTitlebarToolbar.insights:
            configuration = ("Insights", "chart.pie", "Open Insights", #selector(openInsights(_:)))
        case SearchTitlebarToolbar.open:
            configuration = ("Open", "arrow.up.forward.app", "Open selected file", #selector(openSelected(_:)))
        case SearchTitlebarToolbar.reveal:
            configuration = ("Reveal", "folder", "Reveal selected file in Finder", #selector(revealSelected(_:)))
        case SearchTitlebarToolbar.copy:
            configuration = ("Copy Path", "doc.on.doc", "Copy selected path", #selector(copySelectedPath(_:)))
        default:
            return nil
        }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = configuration.label
        item.paletteLabel = configuration.label
        item.toolTip = configuration.tooltip
        item.image = NSImage(
            systemSymbolName: configuration.symbol,
            accessibilityDescription: configuration.tooltip
        )
        item.target = self
        item.action = configuration.action
        item.visibilityPriority = .high
        item.isEnabled = titlebarToolbarItemIsEnabled(itemIdentifier)
        return item
    }

    private func titlebarToolbarItemIsEnabled(_ itemIdentifier: NSToolbarItem.Identifier) -> Bool {
        if SearchTitlebarToolbar.selectionItems.contains(itemIdentifier) {
            return !selectedRecords().isEmpty
        }

        return true
    }

    private func installCenteredTitle(in window: NSWindow) {
        guard centeredTitleLabel == nil else {
            centeredTitleLabel?.stringValue = window.title
            return
        }

        let titlebarGuide = NSLayoutGuide()
        view.addLayoutGuide(titlebarGuide)

        let label = PassthroughTitlebarLabel(labelWithString: window.title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.addSubview(label)

        NSLayoutConstraint.activate([
            titlebarGuide.topAnchor.constraint(equalTo: view.topAnchor),
            titlebarGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            titlebarGuide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            titlebarGuide.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            label.centerXAnchor.constraint(equalTo: titlebarGuide.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: titlebarGuide.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: titlebarGuide.leadingAnchor, constant: 220),
            label.trailingAnchor.constraint(lessThanOrEqualTo: titlebarGuide.trailingAnchor, constant: -220)
        ])
        centeredTitleLabel = label
    }

    private func buildInterface() {
        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .width
        rootStack.spacing = 0
        rootStack.detachesHiddenViews = true
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        let topBar = NSStackView()
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.spacing = 8
        topBar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        let searchBand = ThemedBackgroundView(backgroundColor: Palette.searchBandBackground)
        searchBand.addSubview(topBar)

        searchField.placeholderString = "Search filenames and paths"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldDidChange(_:))
        searchField.controlSize = .large
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        topBar.addArrangedSubview(searchField)

        configureSetupSuggestionPanel()

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = tableView

        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowSizeStyle = .small
        tableView.intercellSpacing = NSSize(width: 3, height: 1)
        tableView.style = .fullWidth
        tableView.allowsMultipleSelection = true
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.doubleAction = #selector(openSelected(_:))
        tableView.target = self
        tableView.openAction = { [weak self] in
            self?.openSelected(nil)
        }
        tableView.copyAction = { [weak self] in
            self?.copySelectedFiles()
        }
        tableView.copyPathAction = { [weak self] in
            self?.copySelectedPath(nil)
        }
        tableView.quickLookAction = { [weak self] in
            self?.quickLookSelected(nil)
        }
        tableView.getInfoAction = { [weak self] in
            self?.getInfoSelected(nil)
        }
        tableView.moveToTrashAction = { [weak self] in
            self?.moveSelectedToTrash(nil)
        }
        tableView.contextMenuTargetRowDidChange = { [weak self] row in
            self?.setContextMenuTargetRow(row)
        }

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        headerMenu.delegate = self
        tableView.headerView?.menu = headerMenu

        for column in Column.allCases where visibleColumns.contains(column) {
            tableView.addTableColumn(makeTableColumn(for: column))
        }
        tableView.sortDescriptors = [sortDescriptor(for: sortSpec)]

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        operationStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .center
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.alignment = .left
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        operationStatusLabel.textColor = .tertiaryLabelColor
        operationStatusLabel.alignment = .right
        operationStatusLabel.lineBreakMode = .byTruncatingTail
        operationStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        operationStatusLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.alignment = .right
        versionLabel.lineBreakMode = .byTruncatingHead
        versionLabel.setContentHuggingPriority(.required, for: .horizontal)
        versionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        configureMascotSlotView()
        mascotCoordinator = OperationMascotCoordinator(imageView: mascotImageView)
        footer.addSubview(mascotSlotView)
        footer.addSubview(statusLabel)
        footer.addSubview(countLabel)
        footer.addSubview(operationStatusLabel)
        footer.addSubview(versionLabel)
        updateMascotPersistentAnimation()

        let titlebarSeparator = NSBox()
        titlebarSeparator.boxType = .separator
        titlebarSeparator.translatesAutoresizingMaskIntoConstraints = false

        rootStack.addArrangedSubview(titlebarSeparator)
        rootStack.addArrangedSubview(searchBand)
        rootStack.addArrangedSubview(setupSuggestionPanel)
        rootStack.addArrangedSubview(scrollView)
        rootStack.addArrangedSubview(footer)
        view.addSubview(rootStack)
        configureIndexingSetupOverlay()
        configureLoadingOverlay()
        configureExpandedMascotOverlay()
        applyFontSettings()

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            searchBand.leadingAnchor.constraint(equalTo: rootStack.leadingAnchor),
            searchBand.trailingAnchor.constraint(equalTo: rootStack.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: searchBand.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: searchBand.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: searchBand.trailingAnchor),
            topBar.bottomAnchor.constraint(equalTo: searchBand.bottomAnchor),
            titlebarSeparator.leadingAnchor.constraint(equalTo: rootStack.leadingAnchor),
            titlebarSeparator.trailingAnchor.constraint(equalTo: rootStack.trailingAnchor),
            titlebarSeparator.heightAnchor.constraint(equalToConstant: 1),
            setupSuggestionPanel.leadingAnchor.constraint(equalTo: rootStack.leadingAnchor),
            setupSuggestionPanel.trailingAnchor.constraint(equalTo: rootStack.trailingAnchor),
            scrollView.leadingAnchor.constraint(equalTo: rootStack.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootStack.trailingAnchor),
            footer.leadingAnchor.constraint(equalTo: rootStack.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: rootStack.trailingAnchor),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: OperationMascotCoordinator.footerSlotHeight + 4),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),

            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 400),

            mascotSlotView.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 14),
            mascotSlotView.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: mascotSlotView.trailingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -16),
            countLabel.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            countLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            operationStatusLabel.leadingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: 16),
            operationStatusLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            operationStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: versionLabel.leadingAnchor, constant: -16),
            versionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: operationStatusLabel.trailingAnchor, constant: 16),
            versionLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -14),
            versionLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),

            loadingOverlay.topAnchor.constraint(equalTo: scrollView.topAnchor),
            loadingOverlay.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            loadingOverlay.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            loadingOverlay.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor)
        ])

        updateActionButtons()
        updateStatus()
        updateSetupSuggestions()
        updateLoadingOverlay()
        updateExpandedMascotForOperation(animated: false)
    }

    private func applyFontSettings() {
        let baseSize = AppSettings.appFontSize(defaults: defaults)
        searchField.font = AppSettings.appFont(defaults: defaults, sizeDelta: 4)
        tableView.rowHeight = max(20, baseSize + 8)
        countLabel.font = AppSettings.appFont(defaults: defaults)
        statusLabel.font = AppSettings.appFont(defaults: defaults)
        operationStatusLabel.font = AppSettings.appFont(defaults: defaults)
        versionLabel.font = AppSettings.appFont(defaults: defaults)
        loadingLabel.font = AppSettings.appFont(defaults: defaults, sizeDelta: 2, weight: .medium)
    }

    private func configureMascotSlotView() {
        mascotSlotView.translatesAutoresizingMaskIntoConstraints = false
        mascotSlotView.wantsLayer = true
        mascotSlotView.layer?.masksToBounds = false
        mascotSlotView.toolTip = "Toggle large Nib"
        mascotSlotView.accessibilityText = "Grow Nib"
        mascotSlotView.onClick = { [weak self] in
            self?.toggleExpandedMascot(nil)
        }
        mascotSlotView.setContentHuggingPriority(.required, for: .horizontal)
        mascotSlotView.setContentCompressionResistancePriority(.required, for: .horizontal)

        mascotSlotView.addSubview(mascotImageView)
        mascotImageView.translatesAutoresizingMaskIntoConstraints = false
        mascotImageView.imageAlignment = .alignCenter
        mascotImageView.toolTip = "Toggle large Nib"
        mascotImageView.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            mascotSlotView.widthAnchor.constraint(equalToConstant: OperationMascotCoordinator.statusDisplaySize),
            mascotSlotView.heightAnchor.constraint(equalToConstant: OperationMascotCoordinator.footerSlotHeight),
            mascotImageView.centerXAnchor.constraint(equalTo: mascotSlotView.centerXAnchor),
            mascotImageView.bottomAnchor.constraint(equalTo: mascotSlotView.bottomAnchor)
        ])
    }

    private func configureExpandedMascotOverlay() {
        expandedMascotView.translatesAutoresizingMaskIntoConstraints = false
        expandedMascotView.wantsLayer = true
        expandedMascotView.layer?.masksToBounds = false
        expandedMascotView.alphaValue = 1
        expandedMascotView.isHidden = true
        expandedMascotView.toolTip = "Shrink Nib"
        expandedMascotView.accessibilityText = "Shrink Nib"
        expandedMascotView.onClick = { [weak self] in
            self?.toggleExpandedMascot(nil)
        }

        expandedMascotView.addSubview(expandedMascotImageView)
        expandedMascotImageView.translatesAutoresizingMaskIntoConstraints = false
        expandedMascotImageView.imageAlignment = .alignCenter
        expandedMascotImageView.setAccessibilityElement(false)
        let coordinator = OperationMascotCoordinator(
            imageView: expandedMascotImageView,
            displaySize: OperationMascotCoordinator.statusDisplaySize
        )

        view.addSubview(expandedMascotView)
        let centerXConstraint = expandedMascotView.centerXAnchor.constraint(
            equalTo: view.leadingAnchor,
            constant: ExpandedMascotLayout.anchorX(for: OperationMascotCoordinator.expandedDisplaySize)
        )
        let imageBottomConstraint = expandedMascotImageView.bottomAnchor.constraint(equalTo: expandedMascotView.bottomAnchor)
        NSLayoutConstraint.activate([
            centerXConstraint,
            expandedMascotView.bottomAnchor.constraint(equalTo: mascotImageView.bottomAnchor),
            expandedMascotView.widthAnchor.constraint(equalToConstant: OperationMascotCoordinator.expandedDisplaySize),
            expandedMascotView.heightAnchor.constraint(equalToConstant: OperationMascotCoordinator.expandedDisplaySize),
            expandedMascotImageView.centerXAnchor.constraint(equalTo: expandedMascotView.centerXAnchor),
            imageBottomConstraint
        ])

        expandedMascotPresenter = ExpandedMascotPresentationController(
            rootView: view,
            footerSlotView: mascotSlotView,
            footerImageView: mascotImageView,
            expandedView: expandedMascotView,
            expandedImageView: expandedMascotImageView,
            animationCoordinator: coordinator,
            centerXConstraint: centerXConstraint,
            imageBottomConstraint: imageBottomConstraint,
            updateHostPlacement: { [weak self] in
                self?.updateMascotPlacementVisibility()
            }
        )
        expandedMascotPresenter?.setPersistentAnimation(persistentMascotAnimation())
    }

    private func configureSetupSuggestionPanel() {
        setupSuggestionPanel.translatesAutoresizingMaskIntoConstraints = false
        setupSuggestionPanel.openFullDiskAccessButton.target = self
        setupSuggestionPanel.openFullDiskAccessButton.action = #selector(openSuggestedFullDiskAccessSettings(_:))
        setupSuggestionPanel.enableGlobalHotKeyButton.target = self
        setupSuggestionPanel.enableGlobalHotKeyButton.action = #selector(enableSuggestedGlobalHotKey(_:))
        setupSuggestionPanel.chooseGlobalHotKeyButton.target = self
        setupSuggestionPanel.chooseGlobalHotKeyButton.action = #selector(chooseSuggestedGlobalHotKey(_:))
        setupSuggestionPanel.dismissGlobalHotKeyButton.target = self
        setupSuggestionPanel.dismissGlobalHotKeyButton.action = #selector(dismissSuggestedGlobalHotKey(_:))
        setupSuggestionPanel.enableGlobalAppSearchHotKeyButton.target = self
        setupSuggestionPanel.enableGlobalAppSearchHotKeyButton.action = #selector(enableSuggestedGlobalAppSearchHotKey(_:))
        setupSuggestionPanel.chooseGlobalAppSearchHotKeyButton.target = self
        setupSuggestionPanel.chooseGlobalAppSearchHotKeyButton.action = #selector(chooseSuggestedGlobalAppSearchHotKey(_:))
        setupSuggestionPanel.dismissGlobalAppSearchHotKeyButton.target = self
        setupSuggestionPanel.dismissGlobalAppSearchHotKeyButton.action = #selector(dismissSuggestedGlobalAppSearchHotKey(_:))
        setupSuggestionPanel.dismissFullDiskAccessButton.target = self
        setupSuggestionPanel.dismissFullDiskAccessButton.action = #selector(dismissSuggestedFullDiskAccess(_:))
    }

    private func configureIndexingSetupOverlay() {
        indexingSetupOverlay.translatesAutoresizingMaskIntoConstraints = false
        indexingSetupOverlay.startIndexingButton.target = self
        indexingSetupOverlay.startIndexingButton.action = #selector(startSuggestedIndexing(_:))
        indexingSetupOverlay.chooseIndexedFoldersButton.target = self
        indexingSetupOverlay.chooseIndexedFoldersButton.action = #selector(chooseSuggestedIndexedFolders(_:))
        setupMascotCoordinator = StandaloneMascotCoordinator(
            imageView: indexingSetupOverlay.mascotImageView,
            clip: .introWelcome,
            displaySize: OperationMascotCoordinator.heroDisplaySize
        )

        mascotFlightImageView.imageScaling = .scaleProportionallyUpOrDown
        mascotFlightImageView.imageAlignment = .alignCenter
        mascotFlightImageView.wantsLayer = true
        mascotFlightImageView.layer?.masksToBounds = false
        mascotFlightImageView.isHidden = true
        mascotFlightImageView.setAccessibilityRole(.image)
        mascotFlightImageView.setAccessibilityLabel("Nib moving into place")

        view.addSubview(indexingSetupOverlay)
        view.addSubview(mascotFlightImageView)
        NSLayoutConstraint.activate([
            indexingSetupOverlay.topAnchor.constraint(equalTo: scrollView.topAnchor),
            indexingSetupOverlay.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            indexingSetupOverlay.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            indexingSetupOverlay.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor)
        ])
    }

    private func updateSetupSuggestions() {
        let needsIndexingSetup = !AppSettings.indexingSetupCompleted(defaults: defaults)
        let appSearchActive = ApplicationSearchQuery.parse(currentSearchText()) != nil
        let needsGlobalHotKey = AppSettings.globalSearchHotKeyNeedsConfirmation(defaults: defaults)
        let needsGlobalAppSearchHotKey = AppSettings.globalAppSearchHotKeyNeedsConfirmation(defaults: defaults)
        let needsFullDiskAccess = !defaults.bool(forKey: AppSettings.fullDiskAccessOnboardingShownKey)
            && (needsIndexingSetup || !FullDiskAccessController.protectedDefaultFoldersCovered(by: indexedRoots).isEmpty)

        let setupOverlayVisible = (needsIndexingSetup && !appSearchActive) || isSetupMascotTuckInProgress
        indexingSetupOverlay.isHidden = !setupOverlayVisible
        indexingSetupOverlay.setMascotVisible(setupOverlayVisible && !isSetupMascotTuckInProgress)
        setupMascotCoordinator?.setActive(setupOverlayVisible && !isSetupMascotTuckInProgress)
        setupSuggestionPanel.update(
            hotKey: AppSettings.globalSearchHotKey(defaults: defaults),
            appHotKey: AppSettings.globalAppSearchHotKey(defaults: defaults),
            needsGlobalHotKey: needsGlobalHotKey,
            needsGlobalAppSearchHotKey: needsGlobalAppSearchHotKey,
            needsFullDiskAccess: needsFullDiskAccess
        )
        updateMascotPlacementVisibility()
    }

    @objc private func enableSuggestedGlobalHotKey(_ sender: NSButton) {
        let hotKey = AppSettings.globalSearchHotKey(defaults: defaults)

        do {
            if let appDelegate = NSApp.delegate as? AppDelegate {
                try appDelegate.saveGlobalSearchHotKey(enabled: true, hotKey: hotKey)
            } else {
                AppSettings.saveGlobalSearchHotKey(enabled: true, hotKey: hotKey, defaults: defaults)
            }
        } catch {
            presentError("Could not register global search hotkey.", informativeText: error.localizedDescription)
        }

        updateSetupSuggestions()
    }

    @objc private func chooseSuggestedGlobalHotKey(_ sender: NSButton) {
        AppSettings.saveGlobalSearchHotKey(
            enabled: false,
            hotKey: AppSettings.globalSearchHotKey(defaults: defaults),
            defaults: defaults
        )
        (NSApp.delegate as? AppDelegate)?.showSettings(section: .hotkeys)
        updateSetupSuggestions()
    }

    @objc private func enableSuggestedGlobalAppSearchHotKey(_ sender: NSButton) {
        let hotKey = AppSettings.globalAppSearchHotKey(defaults: defaults)

        do {
            if let appDelegate = NSApp.delegate as? AppDelegate {
                try appDelegate.saveGlobalAppSearchHotKey(enabled: true, hotKey: hotKey)
            } else {
                AppSettings.saveGlobalAppSearchHotKey(enabled: true, hotKey: hotKey, defaults: defaults)
            }
        } catch {
            presentError("Could not register global app search hotkey.", informativeText: error.localizedDescription)
        }

        updateSetupSuggestions()
    }

    @objc private func chooseSuggestedGlobalAppSearchHotKey(_ sender: NSButton) {
        AppSettings.saveGlobalAppSearchHotKey(
            enabled: false,
            hotKey: AppSettings.globalAppSearchHotKey(defaults: defaults),
            defaults: defaults
        )
        (NSApp.delegate as? AppDelegate)?.showSettings(section: .hotkeys)
        updateSetupSuggestions()
    }

    @objc private func openSuggestedFullDiskAccessSettings(_ sender: NSButton) {
        DiagnosticLogger.shared.log(category: "privacy", event: "fullDiskAccess.openSettingsFromSuggestion")
        markFullDiskAccessOnboardingShown()
        FullDiskAccessController.openSystemSettings()
        updateSetupSuggestions()
    }

    @objc private func dismissSuggestedGlobalHotKey(_ sender: NSButton) {
        AppSettings.saveGlobalSearchHotKey(
            enabled: false,
            hotKey: AppSettings.globalSearchHotKey(defaults: defaults),
            defaults: defaults
        )
        updateSetupSuggestions()
    }

    @objc private func dismissSuggestedGlobalAppSearchHotKey(_ sender: NSButton) {
        AppSettings.saveGlobalAppSearchHotKey(
            enabled: false,
            hotKey: AppSettings.globalAppSearchHotKey(defaults: defaults),
            defaults: defaults
        )
        updateSetupSuggestions()
    }

    @objc private func dismissSuggestedFullDiskAccess(_ sender: NSButton) {
        DiagnosticLogger.shared.log(category: "privacy", event: "fullDiskAccess.dismissSuggestion")
        markFullDiskAccessOnboardingShown()
        updateSetupSuggestions()
    }

    @objc private func startSuggestedIndexing(_ sender: NSButton) {
        let roots = AppSettings.indexedRootsConfigured(defaults: defaults)
            ? AppSettings.indexedRoots(defaults: defaults)
            : AppSettings.suggestedDefaultIndexedRoots()
        beginSetupMascotTuckAwayIfPossible()
        indexedRoots = roots
        refreshRootDisplayNames()
        saveRoots()
        AppSettings.markIndexingSetupCompleted(defaults: defaults)
        rebuildIndexForCurrentSettings()
        updateSetupSuggestions()
    }

    @objc private func chooseSuggestedIndexedFolders(_ sender: NSButton) {
        AppSettings.initializeIndexedRootsWithDefaultsIfNeeded(defaults: defaults)
        (NSApp.delegate as? AppDelegate)?.showSettings(section: .indexedFolders)
        updateSetupSuggestions()
    }

    private func markFullDiskAccessOnboardingShown() {
        defaults.set(true, forKey: AppSettings.fullDiskAccessOnboardingShownKey)
        defaults.synchronize()
    }

    @discardableResult
    private func beginSetupMascotTuckAwayIfPossible() -> Bool {
        guard
            !indexingSetupOverlay.isHidden,
            !isMascotFlightInProgress,
            !isSetupMascotTuckInProgress,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            return false
        }

        view.layoutSubtreeIfNeeded()
        guard let currentImage = indexingSetupOverlay.mascotImageView.image else {
            return false
        }

        let startFrame = indexingSetupOverlay.mascotImageView.convert(indexingSetupOverlay.mascotImageView.bounds, to: view)
        let targetFrame = setupMascotTuckTargetFrame()
        guard !startFrame.isEmpty, !targetFrame.isEmpty else {
            return false
        }

        isSetupMascotTuckInProgress = true
        setupMascotCoordinator?.setActive(false)
        indexingSetupOverlay.setMascotVisible(false)

        return beginMascotFlight(
            image: currentImage,
            startFrame: startFrame,
            targetFrame: targetFrame,
            duration: 0.64,
            playback: .standalone(.flydown)
        ) {
            self.isSetupMascotTuckInProgress = false
            self.indexingSetupOverlay.setMascotVisible(true)
            self.updateSetupSuggestions()
            self.updateExpandedMascotForOperation(animated: true)
            self.updateMascotPlacementVisibility()
        }
    }

    @discardableResult
    private func beginMascotFlight(
        image: NSImage,
        startFrame: NSRect,
        targetFrame: NSRect,
        duration: TimeInterval,
        playback: MascotFlightPlayback? = nil,
        completion: @escaping () -> Void
    ) -> Bool {
        guard !isMascotFlightInProgress, !startFrame.isEmpty, !targetFrame.isEmpty else {
            return false
        }

        isMascotFlightInProgress = true
        mascotFlightImageView.removeFromSuperview()
        view.addSubview(mascotFlightImageView)
        mascotFlightImageView.image = image
        mascotFlightImageView.frame = startFrame
        mascotFlightImageView.alphaValue = 1
        mascotFlightImageView.isHidden = false
        startMascotFlightFramePlayback(playback, fallbackImage: image)
        updateMascotPlacementVisibility()
        view.layoutSubtreeIfNeeded()

        guard let layer = mascotFlightImageView.layer else {
            finishMascotFlight(completion: completion)
            return true
        }

        let startPosition = layer.position
        let startBounds = layer.bounds

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mascotFlightImageView.frame = targetFrame
        view.layoutSubtreeIfNeeded()
        let targetPosition = layer.position
        let targetBounds = layer.bounds
        CATransaction.commit()

        let positionAnimation = CABasicAnimation(keyPath: "position")
        positionAnimation.fromValue = startPosition
        positionAnimation.toValue = targetPosition

        let boundsAnimation = CABasicAnimation(keyPath: "bounds")
        boundsAnimation.fromValue = startBounds
        boundsAnimation.toValue = targetBounds

        let flightAnimation = CAAnimationGroup()
        flightAnimation.animations = [positionAnimation, boundsAnimation]
        flightAnimation.duration = duration
        flightAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        flightAnimation.fillMode = .removed
        flightAnimation.isRemovedOnCompletion = true
        layer.add(flightAnimation, forKey: "mascotFlight")

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.finishMascotFlight(completion: completion)
        }

        return true
    }

    private func finishMascotFlight(completion: () -> Void) {
        mascotFlightFrameTimer?.invalidate()
        mascotFlightFrameTimer = nil
        mascotFlightPlayback = nil
        mascotFlightFallbackImage = nil
        mascotFlightImageView.layer?.removeAnimation(forKey: "mascotFlight")
        mascotFlightImageView.isHidden = true
        mascotFlightImageView.image = nil
        isMascotFlightInProgress = false
        completion()
    }

    private func startMascotFlightFramePlayback(
        _ playback: MascotFlightPlayback?,
        fallbackImage: NSImage
    ) {
        mascotFlightFrameTimer?.invalidate()
        mascotFlightFrameTimer = nil
        mascotFlightPlayback = playback
        mascotFlightFallbackImage = fallbackImage

        guard
            let playback,
            playback.frameCount > 1,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            !isMascotPlaybackSuspended
        else {
            mascotFlightImageView.image = fallbackImage
            return
        }

        mascotFlightFrameIndex = playback.startsFromFirstFrame
            ? 0
            : Int(Date().timeIntervalSinceReferenceDate * playback.framesPerSecond) % playback.frameCount
        renderMascotFlightFrame()

        let frameInterval = 1 / playback.framesPerSecond
        let timer = Timer(timeInterval: frameInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.advanceMascotFlightFrame()
            }
        }
        timer.tolerance = min(0.03, frameInterval * 0.2)
        RunLoop.main.add(timer, forMode: .common)
        mascotFlightFrameTimer = timer
    }

    private func advanceMascotFlightFrame() {
        guard let playback = mascotFlightPlayback else { return }

        if playback.loops {
            mascotFlightFrameIndex = (mascotFlightFrameIndex + 1) % playback.frameCount
        } else {
            mascotFlightFrameIndex = min(mascotFlightFrameIndex + 1, playback.frameCount - 1)
        }
        renderMascotFlightFrame()
    }

    private func renderMascotFlightFrame() {
        guard let playback = mascotFlightPlayback else {
            mascotFlightImageView.image = mascotFlightFallbackImage
            return
        }

        mascotFlightImageView.image = playback.frame(
            from: MascotSpriteSheet.shared,
            index: mascotFlightFrameIndex
        ) ?? mascotFlightFallbackImage
    }

    private func updateMascotFlightFramePlaybackForEnergyMode() {
        guard isMascotFlightInProgress else { return }

        if isMascotPlaybackSuspended {
            mascotFlightFrameTimer?.invalidate()
            mascotFlightFrameTimer = nil
            mascotFlightImageView.image = mascotFlightFallbackImage
            return
        }

        guard mascotFlightFrameTimer == nil, let fallbackImage = mascotFlightFallbackImage else { return }
        startMascotFlightFramePlayback(mascotFlightPlayback, fallbackImage: fallbackImage)
    }

    private func setupMascotTuckTargetFrame() -> NSRect {
        expandedMascotPresenter?.expandedTargetFrame() ?? mascotImageView.convert(mascotImageView.bounds, to: view)
    }

    private func configureLoadingOverlay() {
        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false

        loadingMascotImageView.translatesAutoresizingMaskIntoConstraints = false
        loadingMascotCoordinator = OperationMascotCoordinator(
            imageView: loadingMascotImageView,
            displaySize: OperationMascotCoordinator.heroDisplaySize
        )

        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.alignment = .center
        loadingLabel.lineBreakMode = .byWordWrapping
        loadingLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [loadingMascotImageView, loadingLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12

        loadingOverlay.addSubview(stack)
        view.addSubview(loadingOverlay)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: loadingOverlay.centerYAnchor)
        ])

        loadingMascotCoordinator?.setPersistentAnimation(persistentMascotAnimation())
    }

    private func makeTableColumn(for column: Column) -> NSTableColumn {
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
        tableColumn.title = column.title
        tableColumn.width = column.width
        tableColumn.minWidth = min(column.width, 48)
        tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column != .modified && column != .size)
        return tableColumn
    }

    private func populateHeaderMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        for column in Column.allCases where column != .name {
            let item = NSMenuItem(title: column.menuTitle, action: #selector(toggleColumnVisibility(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            item.state = visibleColumns.contains(column) ? .on : .off
            menu.addItem(item)
        }
    }

    private func actionItem(_ title: String, _ selector: Selector, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    private func openWithMenuItem(enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        item.isEnabled = enabled

        let submenu = NSMenu(title: "Open With")
        guard enabled, let record = fileActionRecord() else {
            let unavailable = NSMenuItem(title: "No Applications", action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            submenu.addItem(unavailable)
            item.submenu = submenu
            return item
        }

        let applicationURLs = NSWorkspace.shared.urlsForApplications(toOpen: record.url)
        if applicationURLs.isEmpty {
            let unavailable = NSMenuItem(title: "No Applications", action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            submenu.addItem(unavailable)
        } else {
            for applicationURL in applicationURLs.prefix(12) {
                let applicationName = FileManager.default.displayName(atPath: applicationURL.path)
                let applicationItem = NSMenuItem(title: applicationName, action: #selector(openSelectedWithApplication(_:)), keyEquivalent: "")
                applicationItem.target = self
                applicationItem.representedObject = applicationURL
                applicationItem.image = NSWorkspace.shared.icon(forFile: applicationURL.path)
                applicationItem.image?.size = NSSize(width: 16, height: 16)
                submenu.addItem(applicationItem)
            }
        }

        submenu.addItem(.separator())
        submenu.addItem(actionItem("Other...", #selector(openSelectedWithOtherApplication(_:)), enabled: true))
        item.submenu = submenu
        return item
    }

    private func terminalMenuItems(enabled: Bool) -> [NSMenuItem] {
        TerminalService.allCases.compactMap { service in
            guard isApplicationInstalled(bundleIdentifiers: service.bundleIdentifiers, fallbackAppNames: service.fallbackAppNames) else {
                return nil
            }

            let item = NSMenuItem(title: service.title, action: #selector(openTerminalHere(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = service.title
            item.isEnabled = enabled
            return item
        }
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
        textField.font = AppSettings.appFont(defaults: defaults)
        cell.addSubview(textField)
        cell.textField = textField

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])

        return cell
    }

    private func makeMatchCell(for identifier: NSUserInterfaceItemIdentifier) -> MatchIconCellView {
        if let reusable = tableView.makeView(withIdentifier: identifier, owner: self) as? MatchIconCellView {
            return reusable
        }

        let cell = MatchIconCellView()
        cell.identifier = identifier
        return cell
    }

    private func configureMatchCell(_ cell: MatchIconCellView, explanation: MatchExplanation?) {
        guard let explanation else {
            cell.configure(icon: nil, color: .clear, placard: nil)
            return
        }

        let presentation = matchPresentation(for: explanation)
        let color = matchColor(for: explanation)
        cell.configure(
            icon: matchIcon(for: presentation.iconClass, accessibilityDescription: presentation.label),
            color: color,
            placard: matchPlacard(for: explanation)
        )
    }

    private func matchPlacard(for explanation: MatchExplanation) -> MatchPlacard {
        let presentation = matchPresentation(for: explanation)
        return MatchPlacard(
            title: presentation.title,
            scoreText: presentation.scoreText,
            detail: presentation.detail,
            reason: explanation.reason,
            color: matchColor(for: explanation)
        )
    }

    private func displayExplanation(
        for result: SearchResult,
        schedulesAsyncExplanation: Bool
    ) -> MatchExplanation? {
        let query = currentSearchText().trimmingCharacters(in: .whitespacesAndNewlines)
        if ApplicationSearchQuery.parse(query) != nil {
            return result.match
        }

        guard !query.isEmpty else {
            return result.match
        }

        let key = ExplanationCacheKey(query: query, recordID: result.record.id)
        if let cached = explanationCache[key] {
            return cached
        }

        if schedulesAsyncExplanation {
            scheduleExplanation(for: result.record, query: query, key: key)
        }

        return result.match
    }

    private func scheduleVisibleExplanations() {
        let query = currentSearchText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard ApplicationSearchQuery.parse(query) == nil else { return }
        guard !query.isEmpty else { return }

        let visibleRows = tableView.rows(in: tableView.visibleRect)
        guard visibleRows.location != NSNotFound, visibleRows.length > 0 else { return }

        let end = min(results.count, visibleRows.location + visibleRows.length)
        guard visibleRows.location < end else { return }

        for row in visibleRows.location..<end {
            let record = results[row].record
            let key = ExplanationCacheKey(query: query, recordID: record.id)
            scheduleExplanation(for: record, query: query, key: key)
        }
    }

    private func scheduleExplanation(for record: FileRecord, query: String, key: ExplanationCacheKey) {
        guard displayedSearchSignature?.query == query else { return }
        guard explanationCache[key] == nil, !pendingExplanationKeys.contains(key) else { return }

        pendingExplanationKeys.insert(key)
        let generation = explanationGeneration
        let token = activeExplanationToken
        explanationQueue.async { [weak self] in
            guard !token.isCancelled else { return }
            let explanation = FuzzyMatcher.explain(record: record, query: query)
            guard !token.isCancelled else { return }

            DispatchQueue.main.async { [weak self] in
                guard
                    let self,
                    self.explanationGeneration == generation,
                    self.activeExplanationToken === token,
                    self.displayedSearchSignature?.query == query
                else {
                    return
                }

                self.pendingExplanationKeys.remove(key)
                guard let explanation else { return }
                self.explanationCache[key] = explanation
                self.reloadVisibleRows(for: record.id)
            }
        }
    }

    private func reloadVisibleRows(for recordID: UInt64) {
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        guard visibleRows.location != NSNotFound, visibleRows.length > 0 else { return }

        let end = min(results.count, visibleRows.location + visibleRows.length)
        guard visibleRows.location < end else { return }

        var rowIndexes = IndexSet()
        for row in visibleRows.location..<end where results[row].record.id == recordID {
            rowIndexes.insert(row)
        }

        guard !rowIndexes.isEmpty else { return }
        tableView.reloadData(
            forRowIndexes: rowIndexes,
            columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
        )
    }

    private func resetExplanationPipeline(keepingCapacity: Bool = true) {
        activeExplanationToken.cancel()
        activeExplanationToken = SearchCancellationToken()
        explanationGeneration &+= 1
        explanationCache.removeAll(keepingCapacity: keepingCapacity)
        pendingExplanationKeys.removeAll(keepingCapacity: keepingCapacity)
    }

    private func scheduleSearch(force: Bool = false) {
        let queryText = currentSearchText()
        let appSearchQuery = ApplicationSearchQuery.parse(queryText)
        guard appSearchQuery != nil || !indexStats.isLoadingSnapshot else { return }

        let request = SearchRequest(query: queryText, sort: sortSpec, includeHidden: showsHiddenFiles)
        if appSearchQuery == nil {
            updateScanSnapshotPublishingPreference(for: request)
        }
        let signature = SearchSignature(
            query: request.query,
            sort: request.sort,
            includeHidden: request.includeHidden
        )
        if appSearchQuery == nil, shouldSuppressEmptySearchDuringIndexing(request: request) {
            suppressEmptySearchDuringIndexing(signature: signature)
            return
        }

        let signatureChanged = signature != scheduledSearchSignature
        guard force || signatureChanged else {
            pendingSearchInputStartedAt = nil
            return
        }

        if activeSearchToken != nil, force, !signatureChanged {
            return
        }

        scheduledSearchSignature = signature

        let redisplaysCurrentSignature = signature == displayedSearchSignature

        activeSearchToken?.cancel()
        pendingPreviewSearchToken = nil
        activeSearchFullFinished = false
        activeSearchNeedsRetryAfterPreview = false
        let token = SearchCancellationToken()
        activeSearchToken = token
        let searchStartedAt: Date
        if redisplaysCurrentSignature, initialQueryElapsed != nil, !hasFinalSearchTiming {
            searchStartedAt = activeSearchStartedAt ?? Date()
            activeSearchStartedAt = searchStartedAt
            isRefiningSearchResults = true
        } else {
            searchStartedAt = pendingSearchInputStartedAt ?? Date()
            activeSearchStartedAt = searchStartedAt
            initialQueryElapsed = nil
            isRefiningSearchResults = false
            hasFinalSearchTiming = false
        }
        pendingSearchInputStartedAt = nil
        queryElapsed = 0
        startSearchStatusTimerIfNeeded()
        updateMascotPersistentAnimation()

        let queryChanged = displayedSearchSignature?.query != signature.query
        if signature != displayedSearchSignature {
            results = []
            if queryChanged {
                resetExplanationPipeline()
            }
            totalMatches = 0
            queryElapsed = 0
            tableView.reloadData()
            updateStatus()
            updateLoadingOverlay()
            updateActionButtons()
        }

        queryGeneration &+= 1
        let generation = queryGeneration
        let index = self.index
        let budgetTimeout = SearchBudgetTimeout()
        let trimmedQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let previewSkipReason = SearchPreviewScheduling.skipReason(
            appSearchActive: appSearchQuery != nil,
            trimmedQuery: trimmedQuery,
            sortColumn: request.sort.column,
            signatureAlreadyDisplayed: signature == displayedSearchSignature
        )
        let shouldRunPreviewSearch = previewSkipReason == nil
        let previewRequest = SearchRequest(
            query: request.query,
            sort: request.sort,
            includeHidden: request.includeHidden,
            mode: .interactivePreview
        )
        let appSearchRoots = appSearchQuery == nil ? [] : AppSettings.appSearchRoots(defaults: defaults)
        let applicationSearchCatalog = self.applicationSearchCatalog

        if shouldRunPreviewSearch {
            pendingPreviewSearchToken = token
            logSearchPreviewScheduled(signature: signature, generation: generation)
            searchPreviewQueue.async { [weak self] in
                guard !token.isCancelled else {
                    DispatchQueue.main.async { [weak self] in
                        self?.logSearchPreviewRejected(
                            signature: signature,
                            reason: "tokenCancelledBeforeStart",
                            generation: generation,
                            token: token
                        )
                    }
                    return
                }
                guard let previewResponse = index.search(previewRequest, shouldCancel: { token.isCancelled }) else {
                    DispatchQueue.main.async { [weak self] in
                        self?.handlePreviewSearchCancelled(
                            signature: signature,
                            token: token,
                            generation: generation,
                            reason: token.isCancelled ? "tokenCancelled" : "nilResponse"
                        )
                    }
                    return
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let generationMatches = self.queryGeneration == generation
                    let tokenMatches = self.activeSearchToken === token
                    guard SearchRunReconciliation.canApplyResponse(
                        generationMatches: generationMatches,
                        tokenMatches: tokenMatches
                    ) else {
                        self.logSearchPreviewRejected(
                            signature: signature,
                            reason: "staleResponse",
                            generation: generation,
                            token: token,
                            generationMatches: generationMatches,
                            tokenMatches: tokenMatches
                        )
                        return
                    }
                    self.applySearchResponse(
                        previewResponse,
                        signature: signature,
                        token: token,
                        searchStartedAt: searchStartedAt,
                        isFinal: false
                    )
                }
            }
        } else if let previewSkipReason {
            logSearchPreviewSkipped(signature: signature, reason: previewSkipReason, generation: generation)
        }

        searchQueue.async {
            guard !token.isCancelled else {
                DispatchQueue.main.async { [weak self] in
                    self?.clearSearchTokenIfCurrent(token)
                }
                return
            }

            let fullSearchStartedAt = Date()
            let shouldCancelSearch: @Sendable () -> Bool = {
                if token.isCancelled {
                    return true
                }
                if
                    appSearchQuery == nil,
                    Self.shouldBudgetSearchDuringIndexing(request: request, stats: index.currentStats()),
                    Date().timeIntervalSince(fullSearchStartedAt) >= SearchScheduling.unoptimizedIndexingSearchBudget
                {
                    budgetTimeout.markTimedOut()
                    return true
                }
                return false
            }
            let response = appSearchQuery.map { appQuery in
                applicationSearchCatalog.search(
                    queryText: appQuery.searchText,
                    roots: appSearchRoots,
                    sort: request.sort,
                    shouldCancel: shouldCancelSearch
                )
            } ?? index.search(request, shouldCancel: shouldCancelSearch)

            guard let response else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let shouldRetry = budgetTimeout.didTimeOut && !self.shouldBudgetSearchDuringIndexing(request: request)
                    let keptPendingPreview = self.handleFullSearchCancelled(
                        signature: signature,
                        token: token,
                        generation: generation,
                        budgetTimedOut: budgetTimeout.didTimeOut,
                        retryAfterPreview: shouldRetry
                    )
                    if shouldRetry, !keptPendingPreview {
                        self.scheduleSearch(force: true)
                    }
                }
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let generationMatches = self.queryGeneration == generation
                let tokenMatches = self.activeSearchToken === token
                guard SearchRunReconciliation.canApplyResponse(
                    generationMatches: generationMatches,
                    tokenMatches: tokenMatches
                ) else {
                    self.logFullSearchRejected(
                        signature: signature,
                        reason: "staleResponse",
                        generation: generation,
                        token: token,
                        generationMatches: generationMatches,
                        tokenMatches: tokenMatches
                    )
                    return
                }
                self.applySearchResponse(
                    response,
                    signature: signature,
                    token: token,
                    searchStartedAt: searchStartedAt,
                    isFinal: true
                )
                if
                    response.usesIndexedCandidates,
                    let responseRevision = response.snapshotRevision,
                    responseRevision < self.indexStats.snapshotRevision,
                    signature == self.scheduledSearchSignature
                {
                    self.scheduleSearch(force: true)
                }
            }
        }
    }

    private func handlePreviewSearchCancelled(
        signature: SearchSignature,
        token: SearchCancellationToken,
        generation: UInt64,
        reason: String
    ) {
        let generationMatches = queryGeneration == generation
        let tokenMatches = activeSearchToken === token
        logSearchPreviewRejected(
            signature: signature,
            reason: reason,
            generation: generation,
            token: token,
            generationMatches: generationMatches,
            tokenMatches: tokenMatches
        )

        guard generationMatches, tokenMatches else { return }
        if pendingPreviewSearchToken === token {
            pendingPreviewSearchToken = nil
        }
        if activeSearchFullFinished {
            clearSearchTokenIfCurrent(token)
        }
    }

    private func handleFullSearchCancelled(
        signature: SearchSignature,
        token: SearchCancellationToken,
        generation: UInt64,
        budgetTimedOut: Bool,
        retryAfterPreview: Bool
    ) -> Bool {
        let generationMatches = queryGeneration == generation
        let tokenMatches = activeSearchToken === token
        let hasPendingPreview = pendingPreviewSearchToken === token
        let reason = budgetTimedOut ? "budgetTimeout" : (token.isCancelled ? "tokenCancelled" : "nilResponse")
        logSearchFullCancelled(
            signature: signature,
            reason: reason,
            generation: generation,
            token: token,
            generationMatches: generationMatches,
            tokenMatches: tokenMatches,
            hasPendingPreview: hasPendingPreview,
            budgetTimedOut: budgetTimedOut,
            retryAfterPreview: retryAfterPreview
        )

        guard generationMatches, tokenMatches else { return false }
        activeSearchFullFinished = true
        activeSearchNeedsRetryAfterPreview = retryAfterPreview
        if SearchRunReconciliation.fullCancellationKeepsSearchActive(
            hasPendingPreview: hasPendingPreview,
            tokenCancelled: token.isCancelled
        ) {
            isRefiningSearchResults = true
            updateStatus()
            updateLoadingOverlay()
            updateMascotPersistentAnimation()
            return true
        }

        activeSearchNeedsRetryAfterPreview = false
        clearSearchTokenIfCurrent(token)
        return false
    }

    private func logSearchPreviewScheduled(signature: SearchSignature, generation: UInt64) {
        DiagnosticLogger.shared.log(
            category: "search",
            event: "search.previewScheduled",
            fields: searchLifecycleFields(signature: signature, reason: "scheduled", generation: generation),
            diagnosticFields: ["query": .query(signature.query)]
        )
    }

    private func logSearchPreviewSkipped(signature: SearchSignature, reason: String, generation: UInt64) {
        DiagnosticLogger.shared.log(
            category: "search",
            event: "search.previewSkipped",
            fields: searchLifecycleFields(signature: signature, reason: reason, generation: generation),
            diagnosticFields: ["query": .query(signature.query)]
        )
    }

    private func logSearchPreviewRejected(
        signature: SearchSignature,
        reason: String,
        generation: UInt64,
        token: SearchCancellationToken,
        generationMatches: Bool? = nil,
        tokenMatches: Bool? = nil
    ) {
        var fields = searchLifecycleFields(signature: signature, reason: reason, generation: generation)
        fields["tokenCancelled"] = .publicBool(token.isCancelled)
        fields["generationMatches"] = .publicBool(generationMatches ?? (queryGeneration == generation))
        fields["tokenMatches"] = .publicBool(tokenMatches ?? (activeSearchToken === token))
        fields["fullSearchFinished"] = .publicBool(activeSearchFullFinished)
        DiagnosticLogger.shared.log(
            category: "search",
            event: "search.previewRejected",
            fields: fields,
            diagnosticFields: ["query": .query(signature.query)]
        )
    }

    private func logSearchFullCancelled(
        signature: SearchSignature,
        reason: String,
        generation: UInt64,
        token: SearchCancellationToken,
        generationMatches: Bool,
        tokenMatches: Bool,
        hasPendingPreview: Bool,
        budgetTimedOut: Bool,
        retryAfterPreview: Bool
    ) {
        var fields = searchLifecycleFields(signature: signature, reason: reason, generation: generation)
        fields["tokenCancelled"] = .publicBool(token.isCancelled)
        fields["generationMatches"] = .publicBool(generationMatches)
        fields["tokenMatches"] = .publicBool(tokenMatches)
        fields["hasPendingPreview"] = .publicBool(hasPendingPreview)
        fields["budgetTimedOut"] = .publicBool(budgetTimedOut)
        fields["retryAfterPreview"] = .publicBool(retryAfterPreview)
        DiagnosticLogger.shared.log(
            category: "search",
            event: "search.fullCancelled",
            fields: fields,
            diagnosticFields: ["query": .query(signature.query)]
        )
    }

    private func logFullSearchRejected(
        signature: SearchSignature,
        reason: String,
        generation: UInt64,
        token: SearchCancellationToken,
        generationMatches: Bool,
        tokenMatches: Bool
    ) {
        var fields = searchLifecycleFields(signature: signature, reason: reason, generation: generation)
        fields["tokenCancelled"] = .publicBool(token.isCancelled)
        fields["generationMatches"] = .publicBool(generationMatches)
        fields["tokenMatches"] = .publicBool(tokenMatches)
        DiagnosticLogger.shared.log(
            category: "search",
            event: "search.fullRejected",
            fields: fields,
            diagnosticFields: ["query": .query(signature.query)]
        )
    }

    private func logFinalSearchRejected(
        _ response: SearchResponse,
        signature: SearchSignature,
        reason: String,
        elapsed: TimeInterval,
        generation: UInt64
    ) {
        var fields = searchResponseLogFields(
            response,
            signature: signature,
            elapsed: elapsed,
            profile: response.executionProfile
        )
        fields["reason"] = .publicString(reason)
        fields["generation"] = .publicUInt64(generation)
        fields["currentSnapshotRevision"] = .publicUInt64(indexStats.snapshotRevision)
        if let responseSnapshotRevision = response.snapshotRevision {
            fields["responseSnapshotRevision"] = .publicUInt64(responseSnapshotRevision)
        }
        DiagnosticLogger.shared.log(
            level: .warning,
            category: "search",
            event: "search.fullRejected",
            fields: fields,
            diagnosticFields: ["query": .query(signature.query)]
        )
    }

    private func searchLifecycleFields(
        signature: SearchSignature,
        reason: String,
        generation: UInt64
    ) -> [String: DiagnosticLogFieldValue] {
        [
            "sortColumn": .publicString(signature.sort.column.rawValue),
            "sortAscending": .publicBool(signature.sort.ascending),
            "includeHidden": .publicBool(signature.includeHidden),
            "reason": .publicString(reason),
            "generation": .publicUInt64(generation)
        ]
    }

    private func searchResponseLogFields(
        _ response: SearchResponse,
        signature: SearchSignature,
        elapsed: TimeInterval,
        profile: SearchExecutionProfile
    ) -> [String: DiagnosticLogFieldValue] {
        [
            "sortColumn": .publicString(signature.sort.column.rawValue),
            "sortAscending": .publicBool(signature.sort.ascending),
            "includeHidden": .publicBool(signature.includeHidden),
            "displayedResultCount": .publicInt(response.results.count),
            "totalMatches": .publicInt(response.totalMatches),
            "uiLatencySeconds": .publicDouble(elapsed),
            "indexLatencySeconds": .publicDouble(response.elapsed),
            "usesIndexedCandidates": .publicBool(response.usesIndexedCandidates),
            "executionPath": .publicString(profile.executionPath.rawValue),
            "indexesUsed": .publicStringArray(profile.indexesUsed.map(\.rawValue).sorted()),
            "candidateCount": .publicInt(profile.candidateCount),
            "scannedRowCount": .publicInt(profile.scannedRowCount),
            "fallbackToFullScan": .publicBool(profile.didFallbackToFullScan),
            "staleRetry": .publicBool(profile.wasStaleRetry)
        ]
    }

    private func applySearchResponse(
        _ response: SearchResponse,
        signature: SearchSignature,
        token: SearchCancellationToken,
        searchStartedAt: Date,
        isFinal: Bool
    ) {
        guard activeSearchToken === token else { return }
        let elapsed = max(Date().timeIntervalSince(searchStartedAt), 0)
        if
            isFinal,
            SearchRunReconciliation.shouldRejectFinalEmptyResponse(
                existingResultCount: results.count,
                displayedMatchesResponseSignature: displayedSearchSignature == signature,
                responseResultCount: response.results.count,
                responseTotalMatches: response.totalMatches,
                responseSnapshotRevision: response.snapshotRevision,
                currentSnapshotRevision: indexStats.snapshotRevision
            )
        {
            logFinalSearchRejected(
                response,
                signature: signature,
                reason: "staleEmptyWouldClearPreview",
                elapsed: elapsed,
                generation: queryGeneration
            )
            activeSearchFullFinished = true
            pendingPreviewSearchToken = nil
            activeSearchToken = nil
            activeSearchNeedsRetryAfterPreview = false
            isRefiningSearchResults = false
            hasFinalSearchTiming = true
            queryElapsed = elapsed
            activeSearchStartedAt = nil
            stopSearchStatusTimer()
            updateStatus()
            updateLoadingOverlay()
            updateActionButtons()
            updateMascotPersistentAnimation()
            if signature == scheduledSearchSignature {
                scheduleSearch(force: true)
            }
            return
        }

        if isFinal {
            activeSearchFullFinished = true
            pendingPreviewSearchToken = nil
            activeSearchToken = nil
            activeSearchNeedsRetryAfterPreview = false
            isRefiningSearchResults = false
            hasFinalSearchTiming = true
            activeSearchStartedAt = nil
            stopSearchStatusTimer()
        } else {
            if pendingPreviewSearchToken === token {
                pendingPreviewSearchToken = nil
            }
            initialQueryElapsed = elapsed
            let completesSearch = SearchRunReconciliation.previewApplicationCompletesSearch(
                fullSearchAlreadyFinished: activeSearchFullFinished
            )
            if completesSearch {
                let needsRetry = activeSearchNeedsRetryAfterPreview
                activeSearchNeedsRetryAfterPreview = false
                activeSearchToken = nil
                isRefiningSearchResults = false
                activeSearchStartedAt = nil
                stopSearchStatusTimer()
                if needsRetry, signature == scheduledSearchSignature {
                    DispatchQueue.main.async { [weak self] in
                        self?.scheduleSearch(force: true)
                    }
                }
            } else {
                isRefiningSearchResults = true
            }
            hasFinalSearchTiming = false
        }
        if displayedSearchSignature?.query != signature.query {
            resetExplanationPipeline()
        }
        results = response.results
        totalMatches = response.totalMatches
        queryElapsed = elapsed
        displayedSearchSignature = signature
        tableView.reloadData()
        scheduleVisibleExplanations()
        updateStatus(refreshesMemory: isFinal)
        updateLoadingOverlay()
        updateActionButtons()
        updateMascotPersistentAnimation()

        let profile = response.executionProfile
        if isFinal {
            DiagnosticLogger.shared.log(
                category: "search",
                event: "search.displayed",
                fields: searchResponseLogFields(
                    response,
                    signature: signature,
                    elapsed: elapsed,
                    profile: profile
                ),
                diagnosticFields: [
                    "query": .query(signature.query)
                ]
            )
        } else {
            DiagnosticLogger.shared.log(
                category: "search",
                event: "search.previewDisplayed",
                fields: searchResponseLogFields(
                    response,
                    signature: signature,
                    elapsed: elapsed,
                    profile: profile
                ),
                diagnosticFields: [
                    "query": .query(signature.query)
                ]
            )
        }
    }

    private func clearSearchTokenIfCurrent(_ token: SearchCancellationToken) {
        guard activeSearchToken === token else { return }
        activeSearchToken = nil
        pendingPreviewSearchToken = nil
        activeSearchFullFinished = false
        activeSearchNeedsRetryAfterPreview = false
        isRefiningSearchResults = false
        activeSearchStartedAt = nil
        stopSearchStatusTimer()
        updateStatus()
        updateLoadingOverlay()
        updateMascotPersistentAnimation()
    }

    private func suppressEmptySearchDuringIndexing(signature: SearchSignature) {
        scheduledSearchSignature = signature
        if activeSearchToken != nil {
            activeSearchToken?.cancel()
            activeSearchToken = nil
            pendingPreviewSearchToken = nil
            activeSearchFullFinished = false
            activeSearchNeedsRetryAfterPreview = false
            activeSearchStartedAt = nil
            stopSearchStatusTimer()
            queryGeneration &+= 1
        }

        if !results.isEmpty || totalMatches != 0 || queryElapsed != 0 || displayedSearchSignature != signature {
            results = []
            if displayedSearchSignature?.query != signature.query {
                resetExplanationPipeline()
            }
            totalMatches = 0
            queryElapsed = 0
            initialQueryElapsed = nil
            isRefiningSearchResults = false
            hasFinalSearchTiming = false
            activeSearchStartedAt = nil
            displayedSearchSignature = signature
            tableView.reloadData()
            updateStatus()
            updateActionButtons()
        }

        updateLoadingOverlay()
        updateMascotPersistentAnimation()
    }

    private func handleStatsChanged(_ stats: IndexStats) {
        let previousStats = indexStats
        indexStats = stats
        markFSEventBaselineIfNeeded(previous: previousStats, current: stats)
        activateQueuedFSEventCatchUpBaselineIfNeeded(previous: previousStats, current: stats)
        markScopedFSEventCatchUpBaselineIfNeeded(previous: previousStats, current: stats)
        runPendingFSEventCatchUpIfNeeded(stats: stats)
        handleMascotTransition(from: previousStats, to: stats)
        updateStatus()
        updateLoadingOverlay()

        guard AppSettings.indexingSetupCompleted(defaults: defaults), !indexedRoots.isEmpty else {
            return
        }

        guard !stats.isLoadingSnapshot else { return }

        guard indexSettingsMatchConfiguredSettings() else {
            startInitialRebuildIfNeeded()
            return
        }

        if stats.indexedCount == 0, !stats.isIndexing {
            startInitialRebuildIfNeeded()
            return
        }

        refreshZeroRowRootRecoveryCandidatesIfNeeded(stats: stats)
        scheduleZeroRowRootRecoveryIfNeeded()

        if stats.snapshotRevision != previousStats.snapshotRevision {
            scheduleSearch(force: true)
        } else {
            scheduleSearch()
        }
    }

    private func shouldSuppressEmptySearchDuringIndexing(request: SearchRequest, stats: IndexStats? = nil) -> Bool {
        let stats = stats ?? indexStats
        return stats.isIndexing
            && !stats.isReconciling
            && stats.searchableCount == 0
            && request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func updateScanSnapshotPublishingPreference(for request: SearchRequest? = nil) {
        let query = request?.query ?? currentSearchText()
        let hasSearchInput = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        index.setPublishesSearchableSnapshotsDuringScan(hasSearchInput)
    }

    private func shouldBudgetSearchDuringIndexing(request: SearchRequest, stats: IndexStats? = nil) -> Bool {
        Self.shouldBudgetSearchDuringIndexing(request: request, stats: stats ?? indexStats)
    }

    nonisolated private static func shouldBudgetSearchDuringIndexing(request: SearchRequest, stats: IndexStats) -> Bool {
        let trimmedQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedQuery.isEmpty
            && stats.isIndexing
            && stats.optimizedCount < stats.searchableCount
    }

    private func startIndexingAfterFirstPaint() {
        guard !didRequestInitialSnapshotLoad else { return }
        didRequestInitialSnapshotLoad = true
        updateLoadingOverlay()

        guard AppSettings.indexingSetupCompleted(defaults: defaults), !indexedRoots.isEmpty else {
            updateStatus()
            updateSetupSuggestions()
            return
        }

        if indexStats.indexedCount > 0 {
            if indexSettingsMatchConfiguredSettings() {
                refreshZeroRowRootRecoveryCandidatesIfNeeded(stats: indexStats)
                scheduleZeroRowRootRecoveryIfNeeded()
            }
            scheduleSearch(force: true)
            return
        }

        if index.hasResumableCheckpoint(for: indexedRoots) {
            startInitialRebuildIfNeeded()
            return
        }

        if index.loadSnapshotInBackground() {
            return
        }

        startInitialRebuildIfNeeded()
    }

    private func startInitialRebuildIfNeeded() {
        guard
            didRequestInitialSnapshotLoad,
            !didRequestInitialRebuild,
            AppSettings.indexingSetupCompleted(defaults: defaults),
            !indexedRoots.isEmpty
        else {
            return
        }

        didRequestInitialRebuild = true
        resetZeroRowRootRecoveryState()
        if !index.hasResumableCheckpoint(for: indexedRoots) {
            prepareFSEventsForFreshIndexBuild()
        }
        updateScanSnapshotPublishingPreference()
        index.replaceRootsAndRebuild(indexedRoots, mode: .resumeIfAvailable)
    }

    private func updateLoadingOverlay() {
        guard AppSettings.indexingSetupCompleted(defaults: defaults), !indexedRoots.isEmpty else {
            loadingOverlaySawActiveLoad = false
            loadingOverlay.isHidden = true
            updateMascotPlacementVisibility()
            return
        }

        let wasShowingLoadingOverlay = !loadingOverlay.isHidden
        let waitingForInitialLoad = !didRequestInitialSnapshotLoad && indexStats.indexedCount == 0
        let shouldShow = indexStats.isLoadingSnapshot || waitingForInitialLoad
        let canFlyDownAfterHiding = loadingOverlaySawActiveLoad

        if shouldShow, indexStats.isLoadingSnapshot {
            loadingOverlaySawActiveLoad = true
        }

        if indexStats.isLoadingSnapshot || waitingForInitialLoad {
            loadingLabel.stringValue = "Loading file list..."
        } else {
            loadingLabel.stringValue = indexStats.status
        }

        if wasShowingLoadingOverlay, !shouldShow, canFlyDownAfterHiding, beginLoadingMascotFlydownIfPossible() {
            loadingOverlaySawActiveLoad = false
            loadingOverlay.isHidden = true
            updateMascotPlacementVisibility()
            return
        }

        if !shouldShow {
            loadingOverlaySawActiveLoad = false
        }
        loadingOverlay.isHidden = !shouldShow
        updateMascotPlacementVisibility()
    }

    @discardableResult
    private func beginLoadingMascotFlydownIfPossible() -> Bool {
        guard
            !isMascotFlightInProgress,
            !isSetupMascotTuckInProgress,
            indexingSetupOverlay.isHidden,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            return false
        }

        view.layoutSubtreeIfNeeded()
        guard let currentImage = loadingMascotImageView.image else {
            return false
        }

        let startFrame = loadingMascotImageView.convert(loadingMascotImageView.bounds, to: view)
        let targetFrame = mascotPlacementTargetFrame()
        guard !startFrame.isEmpty, !targetFrame.isEmpty else {
            return false
        }

        loadingMascotImageView.isHidden = true
        return beginMascotFlight(
            image: currentImage,
            startFrame: startFrame,
            targetFrame: targetFrame,
            duration: 0.64,
            playback: .standalone(.flydown)
        ) {
            self.updateMascotPlacementVisibility()
        }
    }

    private func handleMascotTransition(from previousStats: IndexStats, to nextStats: IndexStats) {
        updateMascotPersistentAnimation()
        updateExpandedMascotForOperation(from: previousStats.phase, animated: true)

        if nextStats.phase == .failed {
            playMascotTransient(.error)
            return
        }

        let completedPhases: Set<IndexPhase> = [.scanning, .optimizing, .saving]
        if completedPhases.contains(previousStats.phase),
           nextStats.phase == .ready,
           !previousStats.isUpdating,
           previousStats.activityPresentation != .backgroundCatchUp {
            playMascotTransient(.success)
        }
    }

    private func updateMascotPersistentAnimation() {
        let animation = persistentMascotAnimation()
        mascotCoordinator?.setPersistentAnimation(animation)
        expandedMascotPresenter?.setPersistentAnimation(animation)
        loadingMascotCoordinator?.setPersistentAnimation(animation)
    }

    private func playMascotTransient(_ animation: OperationMascotAnimation) {
        guard !isMascotFlightInProgress else { return }

        mascotCoordinator?.playTransient(animation)
        expandedMascotPresenter?.playTransient(animation)
        loadingMascotCoordinator?.playTransient(animation)
    }

    @objc private func toggleExpandedMascot(_ sender: Any?) {
        let importantOperationActive = isImportantMascotOperation(indexStats)

        if expandedMascotPresenter?.isExpanded == true {
            userExpandedMascot = false
            if importantOperationActive {
                userCollapsedExpandedMascotDuringOperation = true
            }
            setExpandedMascotVisible(false, animated: true)
            return
        }

        if importantOperationActive {
            userCollapsedExpandedMascotDuringOperation = false
        } else {
            userExpandedMascot = true
        }
        setExpandedMascotVisible(true, animated: true)
    }

    @objc private func toggleMascotPlaybackPaused(_ sender: Any?) {
        isMascotPlaybackPaused.toggle()
        applyMascotPlaybackSuspension()
    }

    @objc private func resetMascotPosition(_ sender: Any?) {
        cancelPendingMascotExpansion()
        userExpandedMascot = false
        userCollapsedExpandedMascotDuringOperation = false
        updateExpandedMascotForOperation(animated: true)
    }

    private func updateExpandedMascotForOperation(from previousPhase: IndexPhase? = nil, animated: Bool) {
        let importantOperationActive = isImportantMascotOperation(indexStats)
        let wasOperationActive = wasImportantMascotOperationActive

        if importantOperationActive && !wasOperationActive {
            userCollapsedExpandedMascotDuringOperation = false
        }
        wasImportantMascotOperationActive = importantOperationActive

        if importantOperationActive {
            if !userCollapsedExpandedMascotDuringOperation,
               shouldAutoExpandMascotForOperation(from: previousPhase, to: indexStats.phase, wasOperationActive: wasOperationActive) {
                scheduleAutoMascotExpansion(animated: animated)
            }
        } else {
            cancelPendingMascotExpansion()
            userCollapsedExpandedMascotDuringOperation = false
            if !userExpandedMascot {
                setExpandedMascotVisible(false, animated: animated)
            }
        }
    }

    private func scheduleAutoMascotExpansion(animated: Bool) {
        guard expandedMascotPresenter?.isExpanded != true, !userExpandedMascot else {
            setExpandedMascotVisible(true, animated: animated)
            return
        }
        guard pendingMascotExpansion == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingMascotExpansion = nil

            guard
                self.isImportantMascotOperation(self.indexStats),
                !self.userCollapsedExpandedMascotDuringOperation
            else {
                return
            }

            if self.isMascotFlightInProgress || !self.loadingOverlay.isHidden || !self.indexingSetupOverlay.isHidden {
                self.scheduleAutoMascotExpansion(animated: animated)
                return
            }

            self.setExpandedMascotVisible(true, animated: animated)
        }

        pendingMascotExpansion = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + ExpandedMascotLayout.autoExpandDelay, execute: workItem)
    }

    private func cancelPendingMascotExpansion() {
        pendingMascotExpansion?.cancel()
        pendingMascotExpansion = nil
    }

    private func shouldAutoExpandMascotForOperation(
        from previousPhase: IndexPhase?,
        to nextPhase: IndexPhase,
        wasOperationActive: Bool
    ) -> Bool {
        if expandedMascotPresenter?.isExpanded == true || userExpandedMascot {
            return true
        }

        switch nextPhase {
        case .scanning, .saving:
            return true
        case .optimizing:
            if let previousPhase {
                return previousPhase == .scanning || previousPhase == .saving
            }
            return wasOperationActive
        case .idle, .loading, .ready, .failed:
            return false
        }
    }

    private func isImportantMascotOperation(_ stats: IndexStats) -> Bool {
        SearchWindowPresentation.isImportantMascotOperation(stats)
    }

    private func mascotPlacementTargetFrame() -> NSRect {
        view.layoutSubtreeIfNeeded()
        return expandedMascotPresenter?.placementTargetFrame() ?? mascotImageView.convert(mascotImageView.bounds, to: view)
    }

    private func setExpandedMascotVisible(_ visible: Bool, animated: Bool) {
        expandedMascotPresenter?.setExpanded(visible, animated: animated, context: currentMascotPresentationContext())
    }

    private var mascotIsExpanded: Bool {
        expandedMascotPresenter?.isExpanded == true
    }

    private func currentMascotPresentationContext() -> MascotPresentationContext {
        MascotPresentationContext(
            setupMascotVisible: !indexingSetupOverlay.isHidden,
            mascotFlightVisible: !mascotFlightImageView.isHidden,
            loadingOverlayVisible: !loadingOverlay.isHidden
        )
    }

    private func updateMascotPlacementVisibility() {
        let context = currentMascotPresentationContext()
        loadingMascotImageView.isHidden = !context.loadingMascotVisible
        expandedMascotPresenter?.updatePlacement(context: context)
    }

    private func persistentMascotAnimation() -> OperationMascotAnimation {
        SearchWindowPresentation.persistentMascotAnimation(
            stats: indexStats,
            hasActiveSearch: activeSearchToken != nil,
            isRefiningSearchResults: isRefiningSearchResults
        )
    }

    private func currentSearchText() -> String {
        (statusPreviewSearchText ?? searchField.currentEditor()?.string ?? searchField.stringValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearchFieldEditing: Bool {
        guard let editor = searchField.currentEditor() else { return false }
        return view.window?.firstResponder === editor
    }

    private func markSearchInputStarted() {
        if let event = NSApp.currentEvent {
            let eventAge = ProcessInfo.processInfo.systemUptime - event.timestamp
            pendingSearchInputStartedAt = Date(timeIntervalSinceNow: -max(eventAge, 0))
        } else {
            pendingSearchInputStartedAt = Date()
        }
    }

    private func settingsDidChange() {
        let updatedHighlightsSearchText = defaults.bool(forKey: AppSettings.highlightSearchTextKey)
        let updatedShowsHiddenFiles = defaults.bool(forKey: AppSettings.showHiddenFilesKey)
        let updatedStatusFooterMode = AppSettings.statusFooterMode(defaults: defaults)
        let updatedAppFontFamilyName = AppSettings.appFontFamilyName(defaults: defaults)
        let updatedAppFontSize = AppSettings.appFontSize(defaults: defaults)

        if updatedHighlightsSearchText != highlightsSearchText {
            highlightsSearchText = updatedHighlightsSearchText
            tableView.reloadData()
        }

        if updatedAppFontFamilyName != appFontFamilyName || updatedAppFontSize != appFontSize {
            appFontFamilyName = updatedAppFontFamilyName
            appFontSize = updatedAppFontSize
            applyFontSettings()
            tableView.reloadData()
        }

        if updatedShowsHiddenFiles != showsHiddenFiles {
            showsHiddenFiles = updatedShowsHiddenFiles
            scheduleSearch(force: true)
        }

        if updatedStatusFooterMode != statusFooterMode {
            statusFooterMode = updatedStatusFooterMode
            updateStatus()
        }
    }

    @objc private nonisolated func userDefaultsDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.settingsDidChange()
            self?.updateSetupSuggestions()
        }
    }

    @objc private func appFontDidChange(_ notification: Notification) {
        settingsDidChange()
    }

    @objc private func statusFooterModeDidChange(_ notification: Notification) {
        settingsDidChange()
    }

    @objc private func matchColorsDidChange(_ notification: Notification) {
        tableView.reloadData()
    }

    @objc private func indexedRootsDidChange(_ notification: Notification) {
        let updatedRoots = AppSettings.indexedRoots(defaults: defaults)
        guard rootPaths(updatedRoots) != rootPaths(indexedRoots) else {
            updateSetupSuggestions()
            updateLoadingOverlay()
            updateStatus()
            updateActionButtons()
            return
        }

        indexedRoots = updatedRoots
        refreshRootDisplayNames()
        resetZeroRowRootRecoveryState()
        didRequestInitialRebuild = false
        guard AppSettings.indexingSetupCompleted(defaults: defaults) else {
            startWatchingIfNeeded()
            updateSetupSuggestions()
            updateStatus()
            updateActionButtons()
            return
        }

        rebuildIndexForCurrentSettings()
        updateSetupSuggestions()
        updateActionButtons()
    }

    @objc private func appSearchRootsDidChange(_ notification: Notification) {
        applicationSearchCatalog.invalidate()
        guard ApplicationSearchQuery.parse(currentSearchText()) != nil else { return }
        scheduledSearchSignature = nil
        scheduleSearch(force: true)
    }

    @objc private func exclusionPatternsDidChange(_ notification: Notification) {
        let patterns = AppSettings.exclusionPatterns(defaults: defaults)
        guard patterns != index.allExclusionPatterns() else { return }

        index.updateExclusionPatterns(patterns)
        resetZeroRowRootRecoveryState()
        guard AppSettings.indexingSetupCompleted(defaults: defaults) else { return }
        rebuildIndexForCurrentSettings()
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        if applyEnergyMode(.interactive) {
            runFSEventsBackedReconciliation(roots: indexedRoots)
        }
        guard !zeroRowRootRecoveryCandidatePaths.isEmpty else { return }
        scheduleZeroRowRootRecoveryIfNeeded()
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        applyEnergyMode(.background)
    }

    private static func currentEnergyMode() -> EnergyMode {
        NSApp.isActive ? .interactive : .background
    }

    @discardableResult
    private func applyEnergyMode(_ mode: EnergyMode, force: Bool = false) -> Bool {
        guard force || energyMode != mode else { return false }

        energyMode = mode
        startWatchingIfNeeded()
        reschedulePendingFSEventFlushIfNeeded()
        restartMemoryStatusPolling()
        applyMascotPlaybackSuspension()
        return true
    }

    private func applyMascotPlaybackSuspension() {
        let suspended = isMascotPlaybackSuspended
        mascotCoordinator?.setPlaybackSuspended(suspended)
        expandedMascotPresenter?.setPlaybackSuspended(suspended)
        loadingMascotCoordinator?.setPlaybackSuspended(suspended)
        setupMascotCoordinator?.setPlaybackSuspended(suspended)
        updateMascotFlightFramePlaybackForEnergyMode()
    }

    private var isMascotPlaybackSuspended: Bool {
        energyMode.suspendsMascotPlayback || isMascotPlaybackPaused
    }

    private func rebuildIndexForCurrentSettings() {
        activeSearchToken?.cancel()
        activeSearchToken = nil
        pendingPreviewSearchToken = nil
        activeSearchFullFinished = false
        activeSearchNeedsRetryAfterPreview = false
        stopSearchStatusTimer()
        scheduledSearchSignature = nil
        displayedSearchSignature = nil
        results.removeAll(keepingCapacity: true)
        totalMatches = 0
        queryElapsed = 0
        initialQueryElapsed = nil
        isRefiningSearchResults = false
        hasFinalSearchTiming = false
        activeSearchStartedAt = nil
        tableView.reloadData()
        updateStatus()
        updateLoadingOverlay()
        updateActionButtons()
        updateMascotPersistentAnimation()

        guard AppSettings.indexingSetupCompleted(defaults: defaults) else {
            updateStatus()
            updateLoadingOverlay()
            updateActionButtons()
            return
        }

        didRequestInitialSnapshotLoad = true
        didRequestInitialRebuild = true
        resetZeroRowRootRecoveryState()
        prepareFSEventsForFreshIndexBuild()
        updateScanSnapshotPublishingPreference()
        index.replaceRootsAndRebuild(indexedRoots, mode: .fresh)
    }

    func reindexConfiguredRootsFromSettings() {
        indexedRoots = AppSettings.indexedRoots(defaults: defaults)
        index.updateExclusionPatterns(AppSettings.exclusionPatterns(defaults: defaults))
        refreshRootDisplayNames()
        guard AppSettings.indexingSetupCompleted(defaults: defaults), !indexedRoots.isEmpty else { return }
        didRequestInitialSnapshotLoad = true
        didRequestInitialRebuild = true
        resetZeroRowRootRecoveryState()
        prepareFSEventsForFreshIndexBuild()
        updateScanSnapshotPublishingPreference()
        index.replaceRootsAndRebuild(indexedRoots, mode: .fresh)
    }

    private func indexSettingsMatchConfiguredSettings() -> Bool {
        guard index.allExclusionPatterns() == AppSettings.exclusionPatterns(defaults: defaults) else {
            return false
        }

        let indexRoots = index.allRoots()
        guard !indexRoots.isEmpty else {
            return indexStats.indexedCount == 0
        }

        return rootPaths(indexRoots) == rootPaths(indexedRoots)
    }

    private func rootPaths(_ roots: [URL]) -> [String] {
        roots.map(\.standardizedFileURL.path)
    }

    private func resetZeroRowRootRecoveryState() {
        pendingZeroRowRootRecoveryWorkItem?.cancel()
        pendingZeroRowRootRecoveryWorkItem = nil
        attemptedZeroRowRootRecoveryPaths.removeAll(keepingCapacity: false)
        zeroRowRootRecoveryCandidatePaths.removeAll(keepingCapacity: false)
        zeroRowRootRecoveryCandidateSnapshotRevision = nil
    }

    private func refreshZeroRowRootRecoveryCandidatesIfNeeded(stats: IndexStats) {
        guard didRequestInitialSnapshotLoad, !stats.isIndexing, !stats.isLoadingSnapshot, stats.phase != .failed else {
            return
        }
        guard zeroRowRootRecoveryCandidateSnapshotRevision != stats.snapshotRevision else {
            return
        }

        let paths = SearchWindowController.zeroRowRootRecoveryCandidatePaths(
            snapshotRoots: index.currentRootInsights(),
            configuredRootPaths: rootPaths(indexedRoots)
        )
        zeroRowRootRecoveryCandidatePaths = paths
        zeroRowRootRecoveryCandidateSnapshotRevision = stats.snapshotRevision
        attemptedZeroRowRootRecoveryPaths = attemptedZeroRowRootRecoveryPaths.intersection(Set(paths))
    }

    private func scheduleZeroRowRootRecoveryIfNeeded() {
        guard !zeroRowRootRecoveryCandidatePaths.isEmpty else { return }
        pendingZeroRowRootRecoveryWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingZeroRowRootRecoveryWorkItem = nil
            self.recoverReadableZeroRowRootsIfNeeded(stats: self.indexStats)
        }
        pendingZeroRowRootRecoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: workItem)
    }

    private func recoverReadableZeroRowRootsIfNeeded(stats: IndexStats) {
        guard didRequestInitialSnapshotLoad, !stats.isIndexing, !stats.isLoadingSnapshot, stats.phase != .failed else {
            return
        }
        guard !zeroRowRootRecoveryCandidatePaths.isEmpty else { return }
        guard activeFSEventReplay == nil, activeFSEventReconciliationID == nil, fseventCatchUpStartedAt == nil else {
            return
        }

        let unattemptedPaths = zeroRowRootRecoveryCandidatePaths.filter { path in
            !attemptedZeroRowRootRecoveryPaths.contains(path)
                && InsightsRootAccessStatus.status(for: path) == .readable
        }
        guard !unattemptedPaths.isEmpty else {
            return
        }

        for path in unattemptedPaths {
            attemptedZeroRowRootRecoveryPaths.insert(path)
        }
        let recoveredPathSet = Set(unattemptedPaths)
        zeroRowRootRecoveryCandidatePaths.removeAll { recoveredPathSet.contains($0) }

        DiagnosticLogger.shared.log(
            category: "index",
            event: "index.zeroRowRootRecoveryRequested",
            fields: [
                "rootCount": .publicInt(unattemptedPaths.count)
            ],
            diagnosticFields: [
                "roots": .pathArray(unattemptedPaths)
            ]
        )
        index.reconcileIndexedRootsInBackground(
            rootURLs: unattemptedPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
    }

    private func pathsIncludingReadableZeroRowRecoveryCandidates(_ paths: [String]) -> [String] {
        guard !zeroRowRootRecoveryCandidatePaths.isEmpty else { return paths }

        var seen = Set(paths)
        var merged = paths
        for path in zeroRowRootRecoveryCandidatePaths where !seen.contains(path) {
            guard InsightsRootAccessStatus.status(for: path) == .readable else { continue }
            seen.insert(path)
            merged.append(path)
        }
        return merged
    }

    private func refreshRootDisplayNames() {
        rootDisplayNames = Self.rootDisplayNames(for: rootPaths(indexedRoots))
    }

    private func markFSEventBaselineIfNeeded(previous: IndexStats, current: IndexStats) {
        guard previous.isIndexing, !current.isIndexing, current.phase == .ready else { return }
        let completedFreshIndex = current.status.hasPrefix("Indexed") && !previous.resumedFromCheckpoint
        let completedFullReconcile = current.status.hasPrefix("Reconciled")
        guard completedFreshIndex || completedFullReconcile else { return }

        let rootPaths = rootPaths(index.allRoots())
        guard !rootPaths.isEmpty else { return }
        if completedFreshIndex {
            runFSEventsBackedReconciliation(roots: index.allRoots())
        } else {
            fseventCursorStore.markBaseline(for: rootPaths)
            startWatchingIfNeeded()
        }
    }

    private func activateQueuedFSEventCatchUpBaselineIfNeeded(previous: IndexStats, current: IndexStats) {
        guard
            !previous.isIndexing,
            current.isIndexing,
            current.activityPresentation == .backgroundCatchUp,
            activeFSEventScopedCatchUpBaseline == nil,
            let queuedBaseline = queuedFSEventScopedCatchUpBaseline
        else {
            return
        }

        queuedFSEventScopedCatchUpBaseline = nil
        activeFSEventScopedCatchUpBaseline = queuedBaseline
    }

    private func markScopedFSEventCatchUpBaselineIfNeeded(previous: IndexStats, current: IndexStats) {
        guard
            previous.isIndexing,
            !current.isIndexing,
            current.phase == .ready,
            current.activityPresentation == .backgroundCatchUp,
            current.status.hasPrefix("Caught up"),
            let baseline = activeFSEventScopedCatchUpBaseline
        else {
            return
        }

        activeFSEventScopedCatchUpBaseline = nil
        fseventCursorStore.markBaseline(for: baseline.rootPaths, eventID: baseline.eventID)
        startWatchingIfNeeded()
        scheduleZeroRowRootRecoveryIfNeeded()
    }

    private func runPendingFSEventCatchUpIfNeeded(stats: IndexStats) {
        guard
            !stats.isIndexing,
            !stats.isLoadingSnapshot,
            activeFSEventReplay == nil,
            activeFSEventReconciliationID == nil,
            let roots = pendingFSEventCatchUpRoots
        else {
            return
        }

        pendingFSEventCatchUpRoots = nil
        runFSEventsBackedReconciliation(roots: roots)
    }

    private func startWatchingIfNeeded() {
        guard AppSettings.indexingSetupCompleted(defaults: defaults), !indexedRoots.isEmpty else {
            cancelFSEventCatchUp()
            watcher.stop()
            return
        }

        watcher.start(roots: indexedRoots, configuration: energyMode.watcherConfiguration) { @MainActor @Sendable [weak self] events in
            self?.coalesceFSEvents(events)
        }
    }

    private func prepareFSEventsForFreshIndexBuild() {
        eventDebounce?.cancel()
        eventDebounce = nil
        pendingEventPaths.removeAll(keepingCapacity: false)
        pendingRecursiveEventPaths.removeAll(keepingCapacity: false)
        cancelFSEventCatchUp()
        fseventCursorStore.markBaseline(for: rootPaths(indexedRoots))
        startWatchingIfNeeded()
    }

    private func runFSEventsBackedReconciliation(roots: [URL]) {
        let roots = roots.map(\.standardizedFileURL)
        guard
            !roots.isEmpty,
            AppSettings.indexingSetupCompleted(defaults: defaults),
            rootPaths(roots) == rootPaths(indexedRoots),
            index.allExclusionPatterns() == AppSettings.exclusionPatterns(defaults: defaults)
        else {
            return
        }

        startWatchingIfNeeded()
        guard !indexStats.isIndexing, activeFSEventReplay == nil, activeFSEventReconciliationID == nil else {
            pendingFSEventCatchUpRoots = roots
            DiagnosticLogger.shared.log(
                category: "fsevents",
                event: "fsevents.reconciliationDeferred",
                fields: [
                    "rootCount": .publicInt(roots.count),
                    "indexing": .publicBool(indexStats.isIndexing),
                    "replayActive": .publicBool(activeFSEventReplay != nil || activeFSEventReconciliationID != nil)
                ],
                diagnosticFields: [
                    "roots": .pathArray(rootPaths(roots))
                ]
            )
            return
        }

        let reconciliationID = UUID()
        activeFSEventReconciliationID = reconciliationID
        fseventCatchUpStartedAt = Date()
        DiagnosticLogger.shared.log(
            category: "fsevents",
            event: "fsevents.reconciliationStarted",
            fields: [
                "rootCount": .publicInt(roots.count)
            ],
            diagnosticFields: [
                "roots": .pathArray(rootPaths(roots))
            ]
        )
        updateStatus()

        let exclusionRules = FileExclusionRules(patterns: index.allExclusionPatterns())
        activeFSEventReplay = fseventReconciler.reconcile(roots: roots, exclusions: exclusionRules) { @MainActor @Sendable [weak self] action in
            guard let self, self.activeFSEventReconciliationID == reconciliationID else { return }
            self.activeFSEventReplay = nil
            self.activeFSEventReconciliationID = nil
            self.fseventCatchUpStartedAt = nil

            switch action {
            case let .reconcile(paths, baselineEventID):
                let paths = self.pathsIncludingReadableZeroRowRecoveryCandidates(paths)
                DiagnosticLogger.shared.log(
                    category: "fsevents",
                    event: "fsevents.reconciliationReconcile",
                    fields: [
                        "pathCount": .publicInt(paths.count)
                    ],
                    diagnosticFields: [
                        "paths": .pathArray(paths)
                    ]
                )
                let result = self.index.reconcileIndexedRootsInBackground(
                    rootURLs: paths.map { URL(fileURLWithPath: $0, isDirectory: true) },
                    activityPresentation: .backgroundCatchUp
                )
                self.handleScopedFSEventCatchUpRequestResult(
                    result,
                    roots: roots,
                    baselineEventID: baselineEventID
                )
            case let .upToDate(baselineEventID):
                DiagnosticLogger.shared.log(
                    category: "fsevents",
                    event: "fsevents.reconciliationUpToDate",
                    fields: [
                        "baselineEventID": .publicUInt64(baselineEventID)
                    ]
                )
                self.fseventCursorStore.markBaseline(for: self.rootPaths(roots), eventID: baselineEventID)
                self.startWatchingIfNeeded()
                self.updateStatus()
                self.scheduleZeroRowRootRecoveryIfNeeded()
            case let .fullReconcile(paths):
                self.activeFSEventScopedCatchUpBaseline = nil
                self.queuedFSEventScopedCatchUpBaseline = nil
                DiagnosticLogger.shared.log(
                    level: .warning,
                    category: "fsevents",
                    event: "fsevents.reconciliationFullReconcile",
                    fields: [
                        "pathCount": .publicInt(paths?.count ?? 0),
                        "paths": .pathArray(paths ?? [])
                    ]
                )
                self.index.recordRecursiveRescan()
                let rootURLs = paths.map(self.pathsIncludingReadableZeroRowRecoveryCandidates)?
                    .map { URL(fileURLWithPath: $0, isDirectory: true) }
                self.index.reconcileIndexedRootsInBackground(
                    rootURLs: rootURLs,
                    activityPresentation: .foreground
                )
            }
        }
    }

    private func handleScopedFSEventCatchUpRequestResult(
        _ result: ReconciliationRequestResult,
        roots: [URL],
        baselineEventID: UInt64
    ) {
        switch result {
        case .started:
            let rootPaths = rootPaths(roots)
            activeFSEventScopedCatchUpBaseline = mergedFSEventScopedCatchUpBaseline(
                activeFSEventScopedCatchUpBaseline,
                rootPaths: rootPaths,
                eventID: baselineEventID
            )
        case .queued:
            let rootPaths = rootPaths(roots)
            queuedFSEventScopedCatchUpBaseline = mergedFSEventScopedCatchUpBaseline(
                queuedFSEventScopedCatchUpBaseline,
                rootPaths: rootPaths,
                eventID: baselineEventID
            )
        case .coveredByActive:
            let rootPaths = rootPaths(roots)
            if activeFSEventScopedCatchUpBaseline?.rootPaths == rootPaths {
                activeFSEventScopedCatchUpBaseline = mergedFSEventScopedCatchUpBaseline(
                    activeFSEventScopedCatchUpBaseline,
                    rootPaths: rootPaths,
                    eventID: baselineEventID
                )
            } else {
                pendingFSEventCatchUpRoots = roots
            }
            DiagnosticLogger.shared.log(
                category: "fsevents",
                event: "fsevents.reconciliationSuppressedDuplicate",
                fields: [
                    "rootCount": .publicInt(roots.count),
                    "baselineEventID": .publicUInt64(baselineEventID)
                ],
                diagnosticFields: [
                    "roots": .pathArray(rootPaths)
                ]
            )
        case .ignored:
            break
        }
    }

    private func mergedFSEventScopedCatchUpBaseline(
        _ existing: (rootPaths: [String], eventID: UInt64)?,
        rootPaths: [String],
        eventID: UInt64
    ) -> (rootPaths: [String], eventID: UInt64) {
        guard let existing, existing.rootPaths == rootPaths else {
            return (rootPaths, eventID)
        }
        return (rootPaths, max(existing.eventID, eventID))
    }

    private func cancelFSEventCatchUp() {
        activeFSEventReplay?.cancel()
        activeFSEventReplay = nil
        activeFSEventReconciliationID = nil
        fseventCatchUpStartedAt = nil
        pendingFSEventCatchUpRoots = nil
        activeFSEventScopedCatchUpBaseline = nil
        queuedFSEventScopedCatchUpBaseline = nil
    }

    private func coalesceFSEvents(_ events: [FileSystemEvent]) {
        pendingEventPaths.formUnion(events.map(\.path))
        pendingRecursiveEventPaths.formUnion(events.filter(\.requiresRecursiveRescan).map(\.path))
        DiagnosticLogger.shared.log(
            category: "fsevents",
            event: "fsevents.eventsReceived",
            fields: [
                "eventCount": .publicInt(events.count),
                "recursiveEventCount": .publicInt(events.filter(\.requiresRecursiveRescan).count)
            ],
            diagnosticFields: [
                "paths": .pathArray(events.map(\.path))
            ]
        )
        scheduleCoalescedFSEventFlush()
    }

    private func scheduleCoalescedFSEventFlush() {
        eventDebounce?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushCoalescedFSEvents()
        }
        eventDebounce = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + energyMode.eventDebounceDelay, execute: workItem)
    }

    private func reschedulePendingFSEventFlushIfNeeded() {
        guard eventDebounce != nil, !pendingEventPaths.isEmpty else { return }
        scheduleCoalescedFSEventFlush()
    }

    private func flushCoalescedFSEvents() {
        eventDebounce = nil
        let paths = Array(pendingEventPaths)
        let recursivePaths = Array(pendingRecursiveEventPaths)
        pendingEventPaths.removeAll(keepingCapacity: false)
        pendingRecursiveEventPaths.removeAll(keepingCapacity: false)
        guard !paths.isEmpty else { return }
        playMascotTransient(.fileChanged)
        index.update(paths: paths)
        if !recursivePaths.isEmpty {
            index.recordRecursiveRescan()
        }
    }

    private func startMemoryStatusPolling() {
        guard memoryStatusTask == nil else { return }

        refreshMemoryStatus()
        memoryStatusTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: self.energyMode.memoryStatusPollInterval)
                guard !Task.isCancelled else { return }
                self.refreshMemoryStatusAndUpdateFooter()
            }
        }
    }

    private func restartMemoryStatusPolling() {
        memoryStatusTask?.cancel()
        memoryStatusTask = nil
        startMemoryStatusPolling()
    }

    private func refreshMemoryStatusAndUpdateFooter() {
        refreshMemoryStatus()
        updateStatus()
    }

    private func refreshMemoryStatus() {
        let usage = ProcessMemorySampler.currentUsage()
        memoryStatusText = ProcessMemoryFormatter.label(for: usage)
        if let usage {
            index.recordMemorySample(bytes: usage.displayBytes)
        }
    }

    private func startSearchStatusTimerIfNeeded() {
        guard searchStatusTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.activeSearchToken != nil else { return }
                self.updateActiveSearchElapsed()
                self.updateStatus()
            }
        }
        searchStatusTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopSearchStatusTimer() {
        searchStatusTimer?.invalidate()
        searchStatusTimer = nil
    }

    private func updateActiveSearchElapsed(now: Date = Date()) {
        guard activeSearchToken != nil, let activeSearchStartedAt else { return }
        queryElapsed = max(now.timeIntervalSince(activeSearchStartedAt), 0)
    }

    private func updateStatus(refreshesMemory: Bool = false) {
        if refreshesMemory {
            refreshMemoryStatus()
        }
        updateActiveSearchElapsed()

        let appSearchActive = ApplicationSearchQuery.parse(currentSearchText()) != nil
        let shownText = "\(results.count.formatted()) shown / \(totalMatches.formatted()) matches"
        guard AppSettings.indexingSetupCompleted(defaults: defaults) || appSearchActive else {
            let footerText = SearchWindowPresentation.detailedFooterText(
                shownText: shownText,
                operationText: "Setup needed",
                detailText: "Choose what AllTheThings can search",
                appSearchScopeText: nil,
                memoryStatusText: memoryStatusText,
                searchElapsedText: nil
            )
            applyFooterStatus(
                shownText: shownText,
                detailedCenterText: footerText.centerText,
                detailedRightText: footerText.rightText,
                detailedOperationText: footerText.operationText
            )
            return
        }

        let appSearchScopeText = appSearchActive
            ? "\(AppSettings.appSearchRoots(defaults: defaults).count.formatted()) app folders"
            : nil
        let searchElapsedStatusText: String?
        if shouldShowSearchElapsedText() {
            searchElapsedStatusText = searchElapsedText()
        } else {
            searchElapsedStatusText = nil
        }

        let footerStatus: SearchWindowPresentation.IndexStatusFooterText
        if activeSearchToken != nil {
            footerStatus = SearchWindowPresentation.IndexStatusFooterText(operationText: "Searching", detailText: "")
        } else if appSearchActive {
            footerStatus = SearchWindowPresentation.IndexStatusFooterText(operationText: "Application search", detailText: "")
        } else {
            footerStatus = indexStatusFooterText()
        }
        let footerText = SearchWindowPresentation.detailedFooterText(
            shownText: shownText,
            operationText: footerStatus.operationText,
            detailText: footerStatus.detailText,
            appSearchScopeText: appSearchScopeText,
            memoryStatusText: memoryStatusText,
            searchElapsedText: searchElapsedStatusText
        )

        applyFooterStatus(
            shownText: shownText,
            detailedCenterText: footerText.centerText,
            detailedRightText: footerText.rightText,
            detailedOperationText: footerText.operationText
        )
    }

    private func applyFooterStatus(
        shownText: String,
        detailedCenterText: String,
        detailedRightText: String,
        detailedOperationText: String
    ) {
        switch statusFooterMode {
        case .simple:
            statusLabel.stringValue = ""
            statusLabel.isHidden = true
            operationStatusLabel.stringValue = ""
            operationStatusLabel.isHidden = true
            countLabel.stringValue = shownText
            versionLabel.stringValue = ""
            versionLabel.isHidden = true
        case .detailed:
            statusLabel.isHidden = false
            statusLabel.stringValue = detailedOperationText
            countLabel.stringValue = detailedCenterText
            operationStatusLabel.isHidden = false
            operationStatusLabel.stringValue = detailedRightText
            versionLabel.isHidden = false
            versionLabel.stringValue = Self.footerVersionText()
        }
    }

    private static func footerVersionText() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return AppRuntimeStatusFormatter.footerVersion(version: version, build: build)
    }

    private func searchElapsedText() -> String {
        SearchWindowPresentation.searchElapsedText(
            queryElapsed: queryElapsed,
            initialQueryElapsed: initialQueryElapsed,
            isRefiningSearchResults: isRefiningSearchResults,
            hasFinalSearchTiming: hasFinalSearchTiming
        )
    }

    private func shouldShowSearchElapsedText() -> Bool {
        SearchWindowPresentation.shouldShowSearchElapsedText(
            displayedSearchSignatureIsSet: displayedSearchSignature != nil || activeSearchToken != nil,
            queryElapsed: queryElapsed,
            initialQueryElapsed: initialQueryElapsed,
            isRefiningSearchResults: isRefiningSearchResults,
            hasFinalSearchTiming: hasFinalSearchTiming
        )
    }

    private func indexStatusFooterText() -> SearchWindowPresentation.IndexStatusFooterText {
        SearchWindowPresentation.indexStatusFooterText(
            indexedRootsIsEmpty: indexedRoots.isEmpty,
            fseventCatchUpStartedAt: fseventCatchUpStartedAt,
            stats: indexStats
        )
    }

    private func updateActionButtons() {
        titlebarToolbar?.validateVisibleItems()
    }

    private func setContextMenuTargetRow(_ row: Int?) {
        contextMenuTargetRow = row
        if tableView.contextMenuTargetRow != row {
            tableView.contextMenuTargetRow = row
        }
    }

    private func moveResultSelection(delta: Int) {
        guard !results.isEmpty else { return }

        let row: Int
        if tableView.selectedRow >= 0 {
            row = min(max(tableView.selectedRow + delta, 0), results.count - 1)
        } else if delta < 0 {
            row = results.count - 1
        } else {
            row = 0
        }

        selectResultRow(row)
    }

    private func openSelectedOrFirstResult() {
        guard !results.isEmpty else { return }

        if tableView.selectedRow < 0 {
            selectResultRow(0)
        }
        openSelected(nil)
    }

    private func selectResultRow(_ row: Int) {
        guard row >= 0, row < results.count else { return }

        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        updateActionButtons()
    }

    private func selectedRecord() -> FileRecord? {
        selectedRecords().first
    }

    private func selectedRecords() -> [FileRecord] {
        tableView.selectedRowIndexes.compactMap { row in
            guard row >= 0, row < results.count else { return nil }
            return results[row].record
        }
    }

    private func fileActionRecord() -> FileRecord? {
        fileActionRecords().first
    }

    private func fileActionRecords() -> [FileRecord] {
        fileActionRowIndexes().compactMap { row in
            guard row >= 0, row < results.count else { return nil }
            return results[row].record
        }
    }

    private func fileActionRow() -> Int? {
        fileActionRowIndexes().first
    }

    private func fileActionRowIndexes() -> IndexSet {
        FileActionTargeting.rowIndexes(
            contextMenuTargetRow: contextMenuTargetRow,
            selectedRowIndexes: tableView.selectedRowIndexes,
            rowCount: results.count
        )
    }

    private func highlightedPath(_ directoryPath: String, explanation: MatchExplanation?) -> NSAttributedString {
        let displayPath = AppSettings.displayPath(directoryPath)
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: AppSettings.appFont(defaults: defaults)
        ]
        return highlightedText(
            displayPath,
            field: .path,
            explanation: explanation,
            baseAttributes: attributes,
            originalPath: directoryPath
        )
    }

    private func highlightedText(
        _ text: String,
        field: MatchField,
        explanation: MatchExplanation?,
        baseAttributes: [NSAttributedString.Key: Any],
        originalPath: String? = nil
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text, attributes: baseAttributes)
        guard highlightsSearchText, let explanation else {
            return attributed
        }

        for span in explanation.spans where span.field == field || (field == .path && span.field == .ancestorPath) {
            guard let range = displayRange(for: span, in: text, originalPath: originalPath) else {
                continue
            }
            attributed.addAttributes(highlightAttributes(for: span.style), range: range)
        }

        return attributed
    }

    private func displayRange(for span: MatchSpan, in displayText: String, originalPath: String?) -> NSRange? {
        var location = span.location
        if
            let originalPath,
            displayText.hasPrefix("~"),
            originalPath.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path)
        {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let homeUTF16Count = home.utf16.count
            if location >= homeUTF16Count {
                location = 1 + (location - homeUTF16Count)
            }
        }

        guard location >= 0, span.length > 0, location + span.length <= displayText.utf16.count else {
            return nil
        }
        return NSRange(location: location, length: span.length)
    }

    private func highlightAttributes(for style: MatchSpanStyle) -> [NSAttributedString.Key: Any] {
        let color = highlightTextColor()
        switch style {
        case .contiguous:
            return [
                .foregroundColor: color,
                .font: AppSettings.appFont(defaults: defaults, weight: .bold)
            ]
        case .subsequence:
            return [
                .foregroundColor: color,
                .font: AppSettings.appFont(defaults: defaults, weight: .bold),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        case .typo:
            return [
                .foregroundColor: color,
                .font: AppSettings.appFont(defaults: defaults, weight: .bold),
                .backgroundColor: color.withAlphaComponent(0.18)
            ]
        }
    }

    private func highlightTextColor() -> NSColor {
        AppTheme.isDarkAppearance(for: view) ? .systemYellow : .systemOrange
    }

    private func matchLabel(for matchClass: MatchClass) -> String {
        switch matchClass {
        case .alias: "Alias"
        case .exact: "Exact"
        case .prefix: "Prefix"
        case .substring: "Text"
        case .near: "Near"
        case .weakPath: "Path"
        case .metadata: "Meta"
        }
    }

    private struct MatchPresentation {
        let label: String
        let title: String
        let scoreText: String
        let detail: String?
        let iconClass: MatchClass
    }

    private func matchPresentation(for explanation: MatchExplanation) -> MatchPresentation {
        let label = matchLabel(for: explanation.matchClass)
        if explanation.isAliasDerived {
            let sourceLabel = "Alias \(label.lowercased())"
            return MatchPresentation(
                label: sourceLabel,
                title: "\(sourceLabel) match",
                scoreText: "Ranks as \(label) - Score \(explanation.score.formatted())",
                detail: "Matched app metadata, not the visible bundle name.",
                iconClass: .alias
            )
        }

        return MatchPresentation(
            label: label,
            title: "\(label) match",
            scoreText: "Score \(explanation.score.formatted())",
            detail: nil,
            iconClass: explanation.matchClass
        )
    }

    private func matchIcon(for matchClass: MatchClass, accessibilityDescription: String) -> NSImage? {
        let candidates: [String] = switch matchClass {
        case .alias:
            ["tag.circle.fill", "tag.circle", "tag.fill", "tag"]
        case .exact:
            ["checkmark.circle.fill", "checkmark.circle"]
        case .prefix:
            ["arrow.right.circle.fill", "arrow.right.circle"]
        case .substring:
            ["magnifyingglass.circle.fill", "magnifyingglass.circle", "magnifyingglass"]
        case .near:
            ["sparkles", "wand.and.stars", "waveform.path.ecg"]
        case .weakPath:
            ["folder.fill", "folder"]
        case .metadata:
            ["tag.fill", "tag"]
        }

        for symbolName in candidates {
            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription) {
                image.isTemplate = true
                return image
            }
        }
        return nil
    }

    private func matchColor(for explanation: MatchExplanation) -> NSColor {
        let baseColor = matchColor(for: explanation.quality)
        guard explanation.isAliasDerived else { return baseColor }

        let aliasColor = AppSettings.matchColor(
            for: .alias,
            isDark: AppTheme.isDarkAppearance(for: view),
            defaults: defaults
        )
        return saturatedColor(
            blendedColor(baseColor, with: aliasColor, fraction: 0.42),
            multiplier: 1.12
        )
    }

    private func matchColor(for quality: MatchQuality) -> NSColor {
        AppSettings.matchColor(
            for: quality.matchClass,
            isDark: AppTheme.isDarkAppearance(for: view),
            defaults: defaults
        )
    }

    private func blendedColor(_ baseColor: NSColor, with overlayColor: NSColor, fraction: CGFloat) -> NSColor {
        let amount = max(0, min(fraction, 1))
        guard
            let base = baseColor.usingColorSpace(.sRGB),
            let overlay = overlayColor.usingColorSpace(.sRGB)
        else {
            return baseColor
        }

        return NSColor(
            srgbRed: base.redComponent * (1 - amount) + overlay.redComponent * amount,
            green: base.greenComponent * (1 - amount) + overlay.greenComponent * amount,
            blue: base.blueComponent * (1 - amount) + overlay.blueComponent * amount,
            alpha: base.alphaComponent
        )
    }

    private func saturatedColor(_ color: NSColor, multiplier: CGFloat) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return color }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        return NSColor(
            calibratedHue: hue,
            saturation: min(saturation * multiplier, 1),
            brightness: min(brightness * 1.03, 1),
            alpha: alpha
        )
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

    private func sortDescriptor(for spec: SortSpec) -> NSSortDescriptor {
        let column = Column.column(for: spec.column) ?? .name
        return NSSortDescriptor(key: column.rawValue, ascending: spec.ascending)
    }

    private func insertVisibleColumn(_ column: Column) {
        let identifier = NSUserInterfaceItemIdentifier(column.rawValue)
        guard tableView.tableColumn(withIdentifier: identifier) == nil else {
            return
        }

        tableView.addTableColumn(makeTableColumn(for: column))

        guard
            let fromIndex = tableView.tableColumns.firstIndex(where: { $0.identifier == identifier }),
            let toIndex = Column.allCases.filter({ visibleColumns.contains($0) }).firstIndex(of: column),
            fromIndex != toIndex
        else {
            return
        }

        tableView.moveColumn(fromIndex, toColumn: toIndex)
    }

    private func removeVisibleColumn(_ column: Column) {
        guard let tableColumn = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue)) else {
            return
        }

        tableView.removeTableColumn(tableColumn)
    }

    private func applySortFallbackIfNeeded(afterHiding column: Column) {
        guard column.sortColumn == sortSpec.column else { return }

        sortSpec = Self.defaultSortSpec
        tableView.sortDescriptors = [sortDescriptor(for: sortSpec)]
        saveSortSpec()
        scheduleSearch(force: true)
    }

    @objc private func openSettings(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.showSettings()
    }

    @objc private func openInsights(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.showInsights()
    }

    @objc private func searchFieldDidChange(_ sender: NSSearchField) {
        statusPreviewSearchText = nil
        markSearchInputStarted()
        scheduleSearch()
        updateSetupSuggestions()
    }

    @objc private func toggleColumnVisibility(_ sender: NSMenuItem) {
        guard
            let rawColumn = sender.representedObject as? String,
            let column = Column(rawValue: rawColumn),
            column != .name
        else {
            return
        }

        if visibleColumns.contains(column) {
            visibleColumns.remove(column)
            removeVisibleColumn(column)
            applySortFallbackIfNeeded(afterHiding: column)
        } else {
            visibleColumns.insert(column)
            insertVisibleColumn(column)
        }

        saveVisibleColumns()
    }

    private func logFileAction(
        _ action: String,
        records: [FileRecord],
        level: DiagnosticLogLevel = .info,
        extraFields: [String: DiagnosticLogFieldValue] = [:]
    ) {
        var fields = extraFields.filter { _, value in
            level == .warning || level == .error || !isDiagnosticOnlyField(value)
        }
        fields["action"] = .publicString(action)
        fields["selectionCount"] = .publicInt(records.count)
        if level == .warning || level == .error {
            fields["paths"] = .pathArray(records.map(\.path))
        }

        var diagnosticFields = extraFields.filter { _, value in
            isDiagnosticOnlyField(value)
        }
        if level != .warning, level != .error {
            diagnosticFields["paths"] = .pathArray(records.map(\.path))
        }
        DiagnosticLogger.shared.log(
            level: level,
            category: "fileAction",
            event: "fileAction.\(action)",
            fields: fields,
            diagnosticFields: diagnosticFields
        )
    }

    private func isDiagnosticOnlyField(_ field: DiagnosticLogFieldValue) -> Bool {
        switch field.privacy {
        case .path, .pathArray, .query, .privateString:
            return true
        case .publicValue, .errorText:
            return false
        }
    }

    @objc private func openSelected(_ sender: Any?) {
        let records = fileActionRecords()
        guard !records.isEmpty else { return }
        index.recordFileAction(.open)
        var failedRecords: [FileRecord] = []
        for record in records where !NSWorkspace.shared.open(record.url) {
            failedRecords.append(record)
        }
        logFileAction(
            "open",
            records: records,
            level: failedRecords.isEmpty ? .info : .warning,
            extraFields: [
                "success": .publicBool(failedRecords.isEmpty),
                "failureCount": .publicInt(failedRecords.count)
            ]
        )
    }

    @objc private func openSelectedWithApplication(_ sender: NSMenuItem) {
        guard
            let applicationURL = sender.representedObject as? URL,
            !fileActionRecords().isEmpty
        else {
            return
        }

        openSelectedRecords(with: applicationURL)
    }

    @objc private func openSelectedWithOtherApplication(_ sender: Any?) {
        guard !fileActionRecords().isEmpty else { return }

        let panel = NSOpenPanel()
        panel.title = "Choose Application"
        panel.prompt = "Open"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let applicationURL = panel.url else { return }
            self?.openSelectedRecords(with: applicationURL)
        }

        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func openSelectedRecords(with applicationURL: URL) {
        let records = fileActionRecords()
        let urls = records.map(\.url)
        guard !urls.isEmpty else { return }

        index.recordFileAction(.open)
        logFileAction(
            "openWithApplication",
            records: records,
            extraFields: [
                "applicationPath": .path(applicationURL.path)
            ]
        )
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.promptsUserIfNeeded = true
        // LaunchServices calls this completion on a concurrent queue; omit it to avoid a main-actor callback trap.
        NSWorkspace.shared.open(
            urls,
            withApplicationAt: applicationURL,
            configuration: configuration,
            completionHandler: nil
        )
    }

    @objc private func revealSelected(_ sender: Any?) {
        let records = fileActionRecords()
        let urls = records.map(\.url)
        guard !urls.isEmpty else { return }
        index.recordFileAction(.reveal)
        logFileAction("reveal", records: records)
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func moveSelectedToTrash(_ sender: Any?) {
        let records = fileActionRecords()
        guard !records.isEmpty else { return }

        var changedPaths: [String] = []
        for record in records {
            do {
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: record.url, resultingItemURL: &trashedURL)
                changedPaths.append(record.path)
            } catch {
                logFileAction(
                    "moveToTrashFailed",
                    records: [record],
                    level: .error,
                    extraFields: [
                        "error": .errorText(error.localizedDescription)
                    ]
                )
                presentError("Could not move item to Trash.", informativeText: error.localizedDescription)
                break
            }
        }

        if !changedPaths.isEmpty {
            index.recordFileAction(.moveToTrash)
            DiagnosticLogger.shared.log(
                category: "fileAction",
                event: "fileAction.moveToTrash",
                fields: [
                    "action": .publicString("moveToTrash"),
                    "selectionCount": .publicInt(changedPaths.count)
                ],
                diagnosticFields: [
                    "paths": .pathArray(changedPaths)
                ]
            )
            playMascotTransient(.fileChanged)
            index.update(paths: changedPaths)
            scheduleSearch(force: true)
        }
    }

    @objc private func getInfoSelected(_ sender: Any?) {
        guard let record = fileActionRecord() else { return }
        let path = appleScriptStringLiteral(record.path)
        let source = """
        tell application "Finder"
            activate
            open information window of (POSIX file "\(path)" as alias)
        end tell
        """

        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            logFileAction(
                "getInfoFailed",
                records: [record],
                level: .error,
                extraFields: [
                    "error": .errorText(error.description)
                ]
            )
            presentError("Could not show item info.", informativeText: error.description)
        } else {
            index.recordFileAction(.getInfo)
            logFileAction("getInfo", records: [record])
        }
    }

    @objc private func renameSelected(_ sender: Any?) {
        guard let record = fileActionRecord() else { return }

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = record.name

        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.informativeText = record.directoryPath
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.rename(record: record, to: field.stringValue)
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func rename(record: FileRecord, to rawName: String) {
        let newName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != record.name else { return }
        guard !newName.contains("/") else {
            logFileAction(
                "renameRejected",
                records: [record],
                level: .warning,
                extraFields: [
                    "reason": .publicString("slashInName"),
                    "requestedName": .privateString(newName)
                ]
            )
            presentError("Could not rename item.", informativeText: "Names cannot contain slashes.")
            return
        }

        let destination = URL(fileURLWithPath: record.directoryPath, isDirectory: true).appendingPathComponent(newName)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            logFileAction(
                "renameRejected",
                records: [record],
                level: .warning,
                extraFields: [
                    "reason": .publicString("destinationExists"),
                    "destination": .path(destination.path)
                ]
            )
            presentError("Could not rename item.", informativeText: "An item named \"\(newName)\" already exists.")
            return
        }

        do {
            try FileManager.default.moveItem(at: record.url, to: destination)
            index.recordFileAction(.rename)
            logFileAction(
                "rename",
                records: [record],
                extraFields: [
                    "destination": .path(destination.path)
                ]
            )
            playMascotTransient(.fileChanged)
            index.update(paths: [record.path, destination.path])
            scheduleSearch(force: true)
        } catch {
            logFileAction(
                "renameFailed",
                records: [record],
                level: .error,
                extraFields: [
                    "destination": .path(destination.path),
                    "error": .errorText(error.localizedDescription)
                ]
            )
            presentError("Could not rename item.", informativeText: error.localizedDescription)
        }
    }

    @objc private func quickLookSelected(_ sender: Any?) {
        let records = fileActionRecords()
        let paths = records.map(\.path)
        guard !paths.isEmpty else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p"] + paths

        do {
            try process.run()
            index.recordFileAction(.quickLook)
            logFileAction("quickLook", records: records)
        } catch {
            logFileAction(
                "quickLookFailed",
                records: records,
                level: .error,
                extraFields: [
                    "error": .errorText(error.localizedDescription)
                ]
            )
            presentError("Could not Quick Look item.", informativeText: error.localizedDescription)
        }
    }

    @objc private func showMatchDetails(_ sender: Any?) {
        guard
            let row = fileActionRow(),
            row >= 0,
            row < results.count,
            let explanation = displayExplanation(for: results[row], schedulesAsyncExplanation: true)
        else {
            return
        }

        let placardView = MatchPlacardView(frame: NSRect(origin: .zero, size: NSSize(width: 316, height: 136)))
        placardView.configure(matchPlacard(for: explanation))

        let viewController = NSViewController()
        viewController.view = placardView
        viewController.preferredContentSize = NSSize(width: 316, height: 136)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = viewController.preferredContentSize
        popover.contentViewController = viewController
        matchDetailsPopover?.close()
        matchDetailsPopover = popover

        let anchorView = matchDetailsAnchorView(forRow: row)
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxX)
    }

    private func matchDetailsAnchorView(forRow row: Int) -> NSView {
        guard
            let matchColumn = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == Column.match.rawValue }),
            let cell = tableView.view(atColumn: matchColumn, row: row, makeIfNecessary: false)
        else {
            return tableView
        }

        return cell
    }

    @objc private func openTerminalHere(_ sender: NSMenuItem) {
        guard
            let serviceTitle = sender.representedObject as? String,
            let record = fileActionRecord()
        else {
            return
        }

        let directoryPath = terminalDirectoryPath(for: record)
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString(directoryPath, forType: .string)
        pasteboard.setPropertyList([directoryPath], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))

        if !NSPerformService(serviceTitle, pasteboard) {
            logFileAction(
                "openTerminalFailed",
                records: [record],
                level: .error,
                extraFields: [
                    "serviceTitle": .publicString(serviceTitle),
                    "directoryPath": .path(directoryPath)
                ]
            )
            presentError("Could not open terminal here.", informativeText: "\(serviceTitle) is not available from Services.")
        } else {
            logFileAction(
                "openTerminal",
                records: [record],
                extraFields: [
                    "serviceTitle": .publicString(serviceTitle),
                    "directoryPath": .path(directoryPath)
                ]
            )
        }
    }

    @objc private func copy(_ sender: Any?) {
        copySelectedFiles()
    }

    private func copySelectedFiles() {
        let records = fileActionRecords()
        guard !records.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(records.map { $0.url as NSURL })
        pasteboard.setString(records.map(\.path).joined(separator: "\n"), forType: .string)
        index.recordFileAction(.copyFile)
        logFileAction("copyFile", records: records)
    }

    @objc private func copySelectedPath(_ sender: Any?) {
        let records = fileActionRecords()
        guard !records.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(records.map(\.path).joined(separator: "\n"), forType: .string)
        index.recordFileAction(.copyPath)
        logFileAction("copyPath", records: records)
    }

    private func terminalDirectoryPath(for record: FileRecord) -> String {
        record.isDirectory ? record.path : record.directoryPath
    }

    private func isApplicationInstalled(bundleIdentifiers: [String], fallbackAppNames: [String]) -> Bool {
        for bundleIdentifier in bundleIdentifiers where NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil {
            return true
        }

        let homeApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        let applicationDirectories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeApplications
        ]

        for directory in applicationDirectories {
            for appName in fallbackAppNames {
                let candidate = directory.appendingPathComponent(appName).appendingPathExtension("app")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return true
                }
            }
        }

        return false
    }

    private func appleScriptStringLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func presentError(_ message: String, informativeText: String) {
        playMascotTransient(.error)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = informativeText

        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func saveRoots() {
        AppSettings.saveIndexedRoots(indexedRoots, defaults: defaults)
    }

    private func saveSortSpec() {
        defaults.set(sortSpec.column.rawValue, forKey: DefaultsKey.sortColumn)
        defaults.set(sortSpec.ascending, forKey: DefaultsKey.sortAscending)
    }

    private func saveVisibleColumns() {
        let ordered = Column.allCases
            .filter { visibleColumns.contains($0) }
            .map(\.rawValue)
        defaults.set(ordered, forKey: DefaultsKey.visibleColumns)
        defaults.set(3, forKey: DefaultsKey.visibleColumnsSchema)
    }

    private static func loadSortSpec(defaults: UserDefaults) -> SortSpec {
        guard
            let rawColumn = defaults.string(forKey: DefaultsKey.sortColumn),
            let column = SortColumn(rawValue: rawColumn),
            Column.column(for: column) != nil
        else {
            return defaultSortSpec
        }

        let ascending = defaults.object(forKey: DefaultsKey.sortAscending) == nil
            ? defaultSortSpec.ascending
            : defaults.bool(forKey: DefaultsKey.sortAscending)
        return SortSpec(column: column, ascending: ascending)
    }

    private static func loadVisibleColumns(defaults: UserDefaults) -> Set<Column> {
        guard let saved = defaults.array(forKey: DefaultsKey.visibleColumns) as? [String] else {
            return defaultVisibleColumns
        }

        var columns = Set(saved.compactMap(Column.init(rawValue:)))
        columns.insert(.name)
        if defaults.integer(forKey: DefaultsKey.visibleColumnsSchema) < 2 {
            columns.insert(.match)
        }
        return columns
    }

    private static func rootDisplayNames(for paths: [String]) -> [String: String] {
        let standardizedPaths = paths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path }
        var componentsByPath: [String: [String]] = [:]
        for path in standardizedPaths {
            let components = URL(fileURLWithPath: path, isDirectory: true)
                .pathComponents
                .filter { $0 != "/" }
            componentsByPath[path] = components.isEmpty ? [path] : components
        }

        var labels: [String: String] = [:]
        for path in standardizedPaths {
            let components = componentsByPath[path] ?? [path]
            var suffixLength = 1
            var label = defaultRootDisplayName(for: path)

            while suffixLength <= components.count {
                let candidate = components.suffix(suffixLength).joined(separator: "/")
                let isUnique = standardizedPaths.allSatisfy { otherPath in
                    guard otherPath != path, let otherComponents = componentsByPath[otherPath] else { return true }
                    return otherComponents.suffix(suffixLength).joined(separator: "/") != candidate
                }
                label = candidate
                if isUnique { break }
                suffixLength += 1
            }

            labels[path] = label
        }

        return labels
    }

    private static func defaultRootDisplayName(for path: String) -> String {
        guard !path.isEmpty else { return "" }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return url.lastPathComponent.isEmpty ? path : url.lastPathComponent
    }

    private static func kindName(for record: FileRecord) -> String {
        if isApplicationBundle(record) {
            return "Application"
        }
        return record.isDirectory ? "Folder" : "File"
    }

    private static func isApplicationBundle(_ record: FileRecord) -> Bool {
        record.isDirectory && record.fileExtension == "app"
    }

    private static func normalizedSortSpec(_ spec: SortSpec, visibleColumns: Set<Column>) -> SortSpec {
        guard let column = Column.column(for: spec.column), visibleColumns.contains(column) else {
            return defaultSortSpec
        }

        return spec
    }
}
