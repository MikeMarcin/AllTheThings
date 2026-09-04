@testable import AllTheThings
import AppKit
import ATTCore
import Carbon.HIToolbox
import Foundation
import Testing

@Suite("Search toolbar")
struct SearchToolbarTests {
    @Test("application activity maps to asynchronous index maintenance requests")
    func applicationActivityMapsToAsynchronousIndexMaintenanceRequests() {
        #expect(
            IndexActivityMaintenanceRequest.applicationActivityChanged(isActive: true)
                == IndexActivityMaintenanceRequest(background: false, promotePendingWork: true)
        )
        #expect(
            IndexActivityMaintenanceRequest.applicationActivityChanged(isActive: false)
                == IndexActivityMaintenanceRequest(background: true, promotePendingWork: false)
        )
    }

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
        let searchField = try #require(textFields(in: view).compactMap { $0 as? SearchQueryField }.first)
        let historyButton = try #require(buttons(in: view).compactMap { $0 as? SearchHistoryPopUpButton }.first)
        let resultsTable = try #require(tableViews(in: view).first { !($0 is SearchHistoryTableView) })
        let historyTable = try #require(tableViews(in: view).compactMap { $0 as? SearchHistoryTableView }.first)

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
        #expect(contentTooltips.contains("Search History (Command-Y); recall with Control-R"))
        #expect(searchField.nextKeyView === historyButton)
        #expect(historyButton.nextKeyView === resultsTable)
        #expect(resultsTable.nextKeyView === searchField)
        #expect(historyTable.nextKeyView === searchField)
        #expect(historyButton.canBecomeKeyView)
        #expect(!titlebarTooltips.contains("Add indexed folder"))
        #expect(!titlebarTooltips.contains("Reindex scopes"))
    }

    @Test("search history stores one clean, deduplicated entry per committed query")
    func searchHistoryStoresOneCleanDeduplicatedEntryPerCommittedQuery() {
        var history = SearchHistory(entries: ["  README  ", "readme", "", "kind:folder", "history:ignored"])

        #expect(history.entries == ["README", "kind:folder"])
        let recordedEmptyQuery = history.record("   ")
        let recordedCaseVariant = history.record("readme", timestamp: Date(timeIntervalSince1970: 1))
        #expect(!recordedEmptyQuery)
        #expect(recordedCaseVariant)
        #expect(history.entries == ["readme", "kind:folder"])
        let recordedImmediateDuplicate = history.record("readme", timestamp: Date(timeIntervalSince1970: 2))
        let recordedHistoryModeQuery = history.record("history:new query")
        #expect(recordedImmediateDuplicate)
        #expect(history.entries == ["readme", "kind:folder"])
        #expect(!recordedHistoryModeQuery)
    }

    @Test("history mode parses a filter and fuzzy matches recent queries")
    func historyModeParsesAndFuzzyMatchesRecentQueries() {
        #expect(SearchHistoryQuery.parse("history:") == SearchHistoryQuery(searchText: ""))
        #expect(SearchHistoryQuery.parse(" HIST:  rdme ") == SearchHistoryQuery(searchText: "rdme"))
        #expect(SearchHistoryQuery.parse("name:history:") == nil)

        let history = SearchHistory(entries: [
            "release notes ext:md",
            "README ext:md",
            "kind:folder project"
        ])
        #expect(history.matching("") == history.entries)
        #expect(history.matching("rdme") == ["README ext:md"])
        #expect(history.matching("project") == ["kind:folder project"])
    }

    @Test("search history sorts by query and timestamp")
    func searchHistorySortsByQueryAndTimestamp() {
        let history = SearchHistory(
            entries: ["bravo", "Alpha", "charlie"],
            timestamps: [200, 100, 300]
        )

        #expect(history.matchingEntries("", sort: SearchHistorySort()).map(\.query)
            == ["charlie", "bravo", "Alpha"])
        #expect(history.matchingEntries(
            "",
            sort: SearchHistorySort(column: .timestamp, ascending: true)
        ).map(\.query) == ["Alpha", "bravo", "charlie"])
        #expect(history.matchingEntries(
            "",
            sort: SearchHistorySort(column: .query, ascending: true)
        ).map(\.query) == ["Alpha", "bravo", "charlie"])
    }

    @Test("one search history entry can be removed")
    func oneSearchHistoryEntryCanBeRemoved() {
        var history = SearchHistory(entries: ["README", "atlas", "kind:folder"])

        let removedAtlas = history.remove("ATLAS")
        #expect(removedAtlas)
        #expect(history.entries == ["README", "kind:folder"])
        let removedMissing = history.remove("missing")
        #expect(!removedMissing)
    }

    @Test("history popup participates in the key view loop")
    @MainActor
    func historyPopUpParticipatesInTheKeyViewLoop() {
        let button = SearchHistoryPopUpButton(frame: .zero, pullsDown: true)
        #expect(button.canBecomeKeyView)
    }

    @Test("Tab cycles from the results table back to the search field")
    @MainActor
    func tabCyclesFromResultsTableBackToSearchField() throws {
        let index = FileIndex(
            applicationName: "AllTheThingsResultsTableTabTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }

        let controller = SearchWindowController(index: index)
        let window = try #require(controller.window)
        let view = try #require(window.contentViewController?.view)
        let searchField = try #require(textFields(in: view).compactMap { $0 as? SearchQueryField }.first)
        let resultsTable = try #require(tableViews(in: view).first { !($0 is SearchHistoryTableView) })

        #expect(window.makeFirstResponder(resultsTable))
        resultsTable.keyDown(with: try keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: UInt16(kVK_Tab)
        ))

        #expect(window.firstResponder === searchField.currentEditor())
    }

    @Test("history dropdown exposes native Tab traversal")
    @MainActor
    func historyDropdownExposesNativeTabTraversal() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(["README"], forKey: AppSettings.searchHistoryKey)

        let index = FileIndex(
            applicationName: "AllTheThingsSearchHistoryMenuTabTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }

        let controller = SearchWindowController(index: index, defaults: defaults)
        let window = try #require(controller.window)
        let view = try #require(window.contentViewController?.view)
        let historyButton = try #require(buttons(in: view).compactMap { $0 as? SearchHistoryPopUpButton }.first)
        let resultsTable = try #require(tableViews(in: view).first { !($0 is SearchHistoryTableView) })
        let menu = try #require(historyButton.menu)
        let hiddenCommandTitles = Set([
            "Traverse Search Controls",
            "Delete Highlighted Search"
        ])
        let hiddenCommands = menu.items.filter { hiddenCommandTitles.contains($0.title) }
        #expect(hiddenCommands.allSatisfy { $0.allowsKeyEquivalentWhenHidden })
        #expect(hiddenCommands.contains {
            $0.keyEquivalent == "\t" && $0.keyEquivalentModifierMask.isEmpty
        })
        #expect(SearchHistoryMenuFocusDirection.resolve(modifiers: []) == .forward)
        #expect(SearchHistoryMenuFocusDirection.resolve(modifiers: [.shift]) == .backward)

        #expect(window.makeFirstResponder(historyButton))
        #expect(menu.performKeyEquivalent(with: try keyEvent(
            characters: "\t",
            modifiers: [],
            keyCode: UInt16(kVK_Tab)
        )))
        try await Task.sleep(for: .milliseconds(20))
        #expect(window.firstResponder === resultsTable)
    }

    @Test("Delete removes the highlighted query from the history dropdown")
    @MainActor
    func deleteRemovesHighlightedQueryFromHistoryDropdown() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(["README", "kind:folder"], forKey: AppSettings.searchHistoryKey)

        let index = FileIndex(
            applicationName: "AllTheThingsSearchHistoryMenuDeleteTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }

        let controller = SearchWindowController(index: index, defaults: defaults)
        let view = try #require(controller.window?.contentViewController?.view)
        let historyButton = try #require(buttons(in: view).compactMap { $0 as? NSPopUpButton }.first {
            $0.toolTip == "Search History (Command-Y); recall with Control-R"
        })
        let menu = try #require(historyButton.menu)
        let readmeItem = try #require(menu.items.first { $0.representedObject as? String == "README" })
        menu.delegate?.menuWillOpen?(menu)
        defer { menu.delegate?.menuDidClose?(menu) }
        menu.delegate?.menu?(menu, willHighlight: readmeItem)

        #expect(menu.performKeyEquivalent(with: try keyEvent(
            characters: "\u{8}",
            modifiers: [],
            keyCode: UInt16(kVK_Delete)
        )))
        try await Task.sleep(for: .milliseconds(20))

        #expect(defaults.stringArray(forKey: AppSettings.searchHistoryKey) == ["kind:folder"])
        #expect(!menu.items.contains { $0.representedObject as? String == "README" })
    }

    @Test("search history retains only the most recent fifty committed queries")
    func searchHistoryRetainsOnlyTheMostRecentFiftyCommittedQueries() {
        var history = SearchHistory()
        for index in 0..<75 {
            history.record("query-\(index)")
        }

        #expect(history.entries.count == SearchHistory.maximumEntryCount)
        #expect(history.entries.first == "query-74")
        #expect(history.entries.last == "query-25")
    }

    @Test("search history supports custom and unlimited retention")
    func searchHistorySupportsCustomAndUnlimitedRetention() {
        var bounded = SearchHistory()
        for index in 0..<12 {
            bounded.record("query-\(index)", maximumEntryCount: 5)
        }
        #expect(bounded.entries == (7..<12).reversed().map { "query-\($0)" })

        var unlimited = SearchHistory()
        for index in 0..<75 {
            unlimited.record("query-\(index)", maximumEntryCount: nil)
        }
        #expect(unlimited.entries.count == 75)
        #expect(SearchHistory(entries: unlimited.entries, maximumEntryCount: nil).entries.count == 75)
    }

    @Test("search history commits one entry after typing settles without waiting for refinement")
    @MainActor
    func searchHistoryCommitsOneEntryAfterTypingSettlesWithoutWaitingForRefinement() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let index = FileIndex(
            applicationName: "AllTheThingsSearchHistoryTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }

        let controller = SearchWindowController(index: index, defaults: defaults)
        let view = try #require(controller.window?.contentViewController?.view)
        let searchField = try #require(textFields(in: view).compactMap { $0 as? SearchQueryField }.first)
        let historyButton = try #require(buttons(in: view).compactMap { $0 as? NSPopUpButton }.first {
            $0.toolTip == "Search History (Command-Y); recall with Control-R"
        })
        #expect(controller.window?.makeFirstResponder(searchField) == true)
        let editor = try #require(searchField.currentEditor() as? NSTextView)

        editor.insertText("a", replacementRange: editor.selectedRange)
        editor.insertText("tlas", replacementRange: editor.selectedRange)
        #expect(defaults.object(forKey: AppSettings.searchHistoryKey) == nil)
        try await Task.sleep(for: .milliseconds(3_250))

        #expect(defaults.stringArray(forKey: AppSettings.searchHistoryKey) == ["atlas"])
        let timestamps = defaults.array(forKey: AppSettings.searchHistoryTimestampsKey) as? [NSNumber]
        #expect((timestamps?.first?.doubleValue ?? 0) > 0)
        #expect(historyButton.itemTitles.contains("atlas"))
    }

    @Test("command Y enters searchable history mode and Return restores a match")
    @MainActor
    func commandYEntersSearchableHistoryModeAndReturnRestoresMatch() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set([
            "release notes ext:md",
            "README ext:md",
            "kind:folder project"
        ], forKey: AppSettings.searchHistoryKey)

        let index = FileIndex(
            applicationName: "AllTheThingsSearchHistoryModeTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }

        let controller = SearchWindowController(index: index, defaults: defaults)
        let contentController = try #require(controller.window?.contentViewController)
        let view = contentController.view
        let searchField = try #require(textFields(in: view).compactMap { $0 as? NSSearchField }.first)
        #expect(controller.window?.makeFirstResponder(searchField) == true)
        let editor = try #require(searchField.currentEditor() as? NSTextView)

        #expect(contentController.tryToPerform(NSSelectorFromString("showSearchHistory:"), with: nil))
        #expect(editor.string == "history:")
        let historyTable = try #require(tableViews(in: view).compactMap { $0 as? SearchHistoryTableView }.first)
        #expect(historyTable.numberOfRows == 3)
        #expect(historyTable.headerView != nil)
        #expect(historyTable.usesAlternatingRowBackgroundColors)
        #expect(historyTable.allowsMultipleSelection)
        #expect(historyTable.tableColumns.map(\.title) == ["Search", "Searched"])

        historyTable.sortDescriptors = [NSSortDescriptor(key: "query", ascending: true)]
        let firstQueryCell = try #require(
            historyTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView
        )
        #expect(firstQueryCell.textField?.stringValue == "kind:folder project")

        editor.insertText("rdme", replacementRange: editor.selectedRange)
        #expect(editor.string == "history:rdme")
        #expect(historyTable.numberOfRows == 1)
        #expect(searchField.performKeyEquivalent(with: try keyEvent(
            characters: "y",
            modifiers: [.command],
            keyCode: UInt16(kVK_ANSI_Y)
        )))
        #expect(editor.string == "history:")
        #expect(historyTable.numberOfRows == 3)

        editor.insertText("rdme", replacementRange: editor.selectedRange)
        #expect(editor.string == "history:rdme")
        #expect(historyTable.numberOfRows == 1)
        #expect(contentController.tryToPerform(
            NSSelectorFromString("restoreSelectedSearchHistoryEntry:"),
            with: nil
        ))
        #expect(editor.string == "README ext:md")
        #expect(defaults.stringArray(forKey: AppSettings.searchHistoryKey)?.first == "README ext:md")
    }

    @Test("Control Shift R returns from a recalled search to the draft")
    @MainActor
    func controlShiftRReturnsFromRecalledSearchToDraft() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(["README", "kind:folder"], forKey: AppSettings.searchHistoryKey)

        let index = FileIndex(
            applicationName: "AllTheThingsSearchHistoryNavigationTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }

        let controller = SearchWindowController(index: index, defaults: defaults)
        let view = try #require(controller.window?.contentViewController?.view)
        let searchField = try #require(textFields(in: view).compactMap { $0 as? SearchQueryField }.first)
        #expect(controller.window?.makeFirstResponder(searchField) == true)
        let editor = try #require(searchField.currentEditor() as? NSTextView)
        editor.insertText("draft", replacementRange: editor.selectedRange)

        #expect(searchField.performKeyEquivalent(with: try keyEvent(
            characters: "r",
            modifiers: [.control],
            keyCode: UInt16(kVK_ANSI_R)
        )))
        #expect(editor.string == "README")
        #expect(searchField.performKeyEquivalent(with: try keyEvent(
            characters: "r",
            modifiers: [.control, .shift],
            keyCode: UInt16(kVK_ANSI_R)
        )))
        #expect(editor.string == "draft")
    }

    @Test("history mode copies and deletes multiple selected searches")
    @MainActor
    func historyModeCopiesAndDeletesMultipleSelectedSearches() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(["README", "kind:folder"], forKey: AppSettings.searchHistoryKey)

        let index = FileIndex(
            applicationName: "AllTheThingsSearchHistoryDeleteTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }

        let controller = SearchWindowController(index: index, defaults: defaults)
        let contentController = try #require(controller.window?.contentViewController)
        let view = contentController.view
        #expect(contentController.tryToPerform(NSSelectorFromString("showSearchHistory:"), with: nil))
        let historyTable = try #require(tableViews(in: view).compactMap { $0 as? SearchHistoryTableView }.first)
        #expect(historyTable.numberOfRows == 2)
        historyTable.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)

        let contextMenu = try #require(historyTable.menu)
        contextMenu.delegate?.menuNeedsUpdate?(contextMenu)
        #expect(contextMenu.items.map(\.title) == ["Copy", "", "Delete Searches from History"])

        historyTable.keyDown(with: try keyEvent(
            characters: "c",
            modifiers: [.command],
            keyCode: UInt16(kVK_ANSI_C)
        ))
        #expect(NSPasteboard.general.string(forType: .string) == "README\nkind:folder")

        historyTable.keyDown(with: try keyEvent(
            characters: "\u{8}",
            modifiers: [],
            keyCode: UInt16(kVK_Delete)
        ))

        #expect(historyTable.numberOfRows == 0)
        #expect(defaults.object(forKey: AppSettings.searchHistoryKey) == nil)
        #expect(defaults.object(forKey: AppSettings.searchHistoryTimestampsKey) == nil)
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
        #expect(SearchWindowPresentation.shownResultsText(
            resultCount: 3,
            totalMatches: 3,
            completeness: .partial
        ) == "3 shown • refining")
        #expect(SearchWindowPresentation.shownResultsText(
            resultCount: 3,
            totalMatches: 8,
            completeness: .complete
        ) == "3 shown / 8 matches")
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

    @Test("search retry timing remains active while refining")
    func searchRetryTimingRemainsActiveWhileRefining() {
        #expect(SearchRunReconciliation.searchTimingIsActive(
            hasActiveSearch: true,
            isRefiningSearchResults: false
        ))
        #expect(SearchRunReconciliation.searchTimingIsActive(
            hasActiveSearch: false,
            isRefiningSearchResults: true
        ))
        #expect(!SearchRunReconciliation.searchTimingIsActive(
            hasActiveSearch: false,
            isRefiningSearchResults: false
        ))

        let initialStart = Date(timeIntervalSinceReferenceDate: 100)
        let retryTime = Date(timeIntervalSinceReferenceDate: 200)
        #expect(SearchRunReconciliation.refiningSearchStartedAt(
            isAlreadyRefining: true,
            activeSearchStartedAt: initialStart,
            now: retryTime
        ) == initialStart)
        #expect(SearchRunReconciliation.refiningSearchStartedAt(
            isAlreadyRefining: false,
            activeSearchStartedAt: initialStart,
            now: retryTime
        ) == retryTime)
    }

    @Test("search previews refresh after the snapshot advances")
    func searchPreviewsRefreshAfterSnapshotAdvances() {
        #expect(SearchRunReconciliation.previewNeedsRefresh(
            displayedSnapshotRevision: 41,
            currentSnapshotRevision: 42
        ))
        #expect(!SearchRunReconciliation.previewNeedsRefresh(
            displayedSnapshotRevision: 42,
            currentSnapshotRevision: 42
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

    @Test("deferred exact retry stops timing after its preview finishes")
    func deferredExactRetryStopsTimingAfterPreviewFinishes() {
        #expect(SearchRunReconciliation.fullCancellationKeepsSearchActive(
            hasPendingPreview: true,
            tokenCancelled: false
        ))
        #expect(SearchRunReconciliation.previewApplicationCompletesSearch(fullSearchAlreadyFinished: true))
        #expect(!SearchRunReconciliation.searchTimingIsActive(
            hasActiveSearch: false,
            isRefiningSearchResults: false
        ))
    }

    @Test("search preview scheduling allows sortable columns")
    func searchPreviewSchedulingAllowsSortableColumns() {
        for sortColumn in SortColumn.allCases {
            #expect(SearchPreviewScheduling.skipReason(
                appSearchActive: false,
                trimmedQuery: "test",
                sortColumn: sortColumn,
                signatureAlreadyDisplayed: false,
                displayedSnapshotIsCurrent: true
            ) == nil)
        }
    }

    @Test("search preview scheduling refreshes a displayed query for a newer snapshot")
    func searchPreviewSchedulingRefreshesDisplayedQueryForNewerSnapshot() {
        #expect(SearchPreviewScheduling.skipReason(
            appSearchActive: false,
            trimmedQuery: "siftworkspace",
            sortColumn: .size,
            signatureAlreadyDisplayed: true,
            displayedSnapshotIsCurrent: false
        ) == nil)
        #expect(SearchPreviewScheduling.skipReason(
            appSearchActive: false,
            trimmedQuery: "siftworkspace",
            sortColumn: .size,
            signatureAlreadyDisplayed: true,
            displayedSnapshotIsCurrent: true
        ) == "alreadyDisplayed")
    }

    @Test("preview scheduler replaces queued work with the latest request")
    func previewSchedulerReplacesQueuedWorkWithLatestRequest() throws {
        let executor = ManualSearchPreviewExecutor()
        let recorder = SearchPreviewWorkRecorder()
        let scheduler = SearchPreviewScheduler(enqueue: executor.enqueue)

        scheduler.schedule { recorder.run(1) }
        scheduler.schedule { recorder.run(2) }
        scheduler.schedule { recorder.run(3) }

        #expect(executor.queuedCount == 1)
        try executor.runNext()
        #expect(executor.queuedCount == 1)
        try executor.runNext()

        #expect(executor.queuedCount == 0)
        #expect(recorder.completedWork == [1, 3])
        #expect(recorder.maximumConcurrentWork == 1)
    }

    @Test("preview scheduler never starts pending work concurrently")
    func previewSchedulerNeverStartsPendingWorkConcurrently() throws {
        let executor = ManualSearchPreviewExecutor()
        let recorder = SearchPreviewWorkRecorder()
        let scheduler = SearchPreviewScheduler(enqueue: executor.enqueue)

        scheduler.schedule {
            recorder.begin(1)
            scheduler.schedule { recorder.run(2) }
            recorder.observeQueuedWork(executor.queuedCount)
            recorder.end(1)
        }

        try executor.runNext()
        #expect(recorder.observedQueuedWork == [0])
        #expect(executor.queuedCount == 1)
        try executor.runNext()

        #expect(recorder.completedWork == [1, 2])
        #expect(recorder.maximumConcurrentWork == 1)
    }

    @Test("background search refreshes coalesce until the app becomes interactive")
    func backgroundSearchRefreshesCoalesceUntilInteractive() {
        var gate = SearchRefreshGate()

        let firstBackgroundRequestRuns = gate.request(isInteractive: false)
        let secondBackgroundRequestRuns = gate.request(isInteractive: false)
        #expect(!firstBackgroundRequestRuns)
        #expect(!secondBackgroundRequestRuns)
        #expect(gate.hasDeferredRefresh)
        let interactiveRequestRuns = gate.request(isInteractive: true)
        #expect(interactiveRequestRuns)
        #expect(gate.hasDeferredRefresh)
        gate.refreshDidStart()
        #expect(!gate.hasDeferredRefresh)
    }

    @Test("FSEvent cursors commit completed batches in receipt order")
    func fseventCursorBatchesCommitInOrder() throws {
        var queue = FSEventCursorCommitQueue()
        let root = "/tmp/allthethings/root-a"
        let firstBatchID = queue.enqueue([root: 41])
        let secondBatchID = queue.enqueue([root: 45])
        let first = try #require(firstBatchID)
        let second = try #require(secondBatchID)

        #expect(queue.markReady([second]).isEmpty)
        #expect(queue.markReady([first]) == [root: 45])
    }

    @Test("FSEvent catch-up barrier holds live cursors until repair completes")
    func fseventCatchUpBarrierHoldsLiveCursors() throws {
        var queue = FSEventCursorCommitQueue()
        let root = "/tmp/allthethings/root-a"
        let barrier = queue.enqueueBarrier()
        let liveBatchID = queue.enqueue([root: 45])
        let liveBatch = try #require(liveBatchID)

        #expect(queue.markReady([liveBatch]).isEmpty)
        #expect(queue.markReady([barrier]) == [root: 45])
    }

    @Test("FSEvent catch-up suspension holds batches queued before its barrier")
    func fseventCatchUpSuspensionHoldsPreexistingBatches() {
        var gate = FSEventCursorCommitGate()
        let root = "/tmp/allthethings/root-a"

        gate.suspend()
        #expect(gate.accept([root: 41]).isEmpty)
        #expect(gate.accept([root: 45]).isEmpty)
        #expect(gate.resume() == [root: 45])
        #expect(!gate.isSuspended)
    }

    @Test("FSEvent cursor epoch reset discards older queued batches")
    func fseventCursorEpochResetDiscardsOlderBatches() throws {
        var queue = FSEventCursorCommitQueue()
        let root = "/tmp/allthethings/root-a"
        let obsoleteBatchID = queue.enqueue([root: 10_000])
        let obsoleteBatch = try #require(obsoleteBatchID)

        queue.removeAll()
        let resetBatchID = queue.enqueue([root: 20])
        let resetBatch = try #require(resetBatchID)

        #expect(queue.markReady([obsoleteBatch]).isEmpty)
        #expect(queue.markReady([resetBatch]) == [root: 20])
    }

    @Test("launch sort resets unless remember sort is enabled")
    func launchSortResetsUnlessRememberSortIsEnabled() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        AppSettings.registerDefaults(defaults)
        defaults.set(SortColumn.created.rawValue, forKey: SearchSortPersistence.sortColumnKey)
        defaults.set(false, forKey: SearchSortPersistence.sortAscendingKey)

        let visibleSortColumns = Set(SortColumn.allCases)
        #expect(SearchSortPersistence.initialSortSpec(
            defaults: defaults,
            visibleSortColumns: visibleSortColumns
        ) == SearchSortPersistence.defaultSortSpec)

        AppSettings.saveRememberSortBetweenLaunches(true, defaults: defaults)

        #expect(SearchSortPersistence.initialSortSpec(
            defaults: defaults,
            visibleSortColumns: visibleSortColumns
        ) == SortSpec(column: .created, ascending: false))
    }

    @Test("launch sort normalizes invalid and hidden saved columns")
    func launchSortNormalizesInvalidAndHiddenSavedColumns() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        AppSettings.registerDefaults(defaults)
        AppSettings.saveRememberSortBetweenLaunches(true, defaults: defaults)

        defaults.set("not-a-column", forKey: SearchSortPersistence.sortColumnKey)
        #expect(SearchSortPersistence.initialSortSpec(
            defaults: defaults,
            visibleSortColumns: Set(SortColumn.allCases)
        ) == SearchSortPersistence.defaultSortSpec)

        defaults.set(SortColumn.size.rawValue, forKey: SearchSortPersistence.sortColumnKey)
        defaults.set(false, forKey: SearchSortPersistence.sortAscendingKey)
        #expect(SearchSortPersistence.initialSortSpec(
            defaults: defaults,
            visibleSortColumns: [.name, .modified]
        ) == SearchSortPersistence.defaultSortSpec)
    }

    @Test("search run reconciliation rejects stale responses")
    func searchRunReconciliationRejectsStaleResponses() {
        #expect(SearchRunReconciliation.canApplyResponse(generationMatches: true, tokenMatches: true))
        #expect(!SearchRunReconciliation.canApplyResponse(generationMatches: false, tokenMatches: true))
        #expect(!SearchRunReconciliation.canApplyResponse(generationMatches: true, tokenMatches: false))
        #expect(SearchRunReconciliation.shouldRejectStaleFinalResponse(
            responseSnapshotRevision: 3,
            currentSnapshotRevision: 4
        ))
        #expect(!SearchRunReconciliation.shouldRejectStaleFinalResponse(
            responseSnapshotRevision: 4,
            currentSnapshotRevision: 4
        ))
        #expect(SearchRunReconciliation.shouldRetryStaleFinalResponse(
            responseSnapshotRevision: 3,
            currentSnapshotRevision: 4,
            signatureStillScheduled: true
        ))
        #expect(!SearchRunReconciliation.shouldRetryStaleFinalResponse(
            responseSnapshotRevision: 3,
            currentSnapshotRevision: 4,
            signatureStillScheduled: false
        ))
    }

    @Test("result identity remapping preserves selection across reorder")
    func resultIdentityRemappingPreservesSelectionAcrossReorder() {
        let reordered: [UInt64] = [30, 10, 40, 20]
        #expect(ResultIdentityRemapping.rowIndexes(
            recordIDs: [10, 20],
            resultRecordIDs: reordered
        ) == IndexSet([1, 3]))
        #expect(ResultIdentityRemapping.row(recordID: 20, resultRecordIDs: reordered) == 3)
        #expect(ResultIdentityRemapping.row(recordID: 99, resultRecordIDs: reordered) == nil)
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
    private func tableViews(in view: NSView?) -> [NSTableView] {
        guard let view else { return [] }
        let current = (view as? NSTableView).map { [$0] } ?? []
        return view.subviews.reduce(current) { partial, subview in
            partial + tableViews(in: subview)
        }
    }

    private func keyEvent(
        characters: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
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

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "AllTheThingsToolbarTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

private final class ManualSearchPreviewExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var queuedWork: [SearchPreviewScheduler.Work] = []

    var queuedCount: Int {
        lock.withLock { queuedWork.count }
    }

    func enqueue(_ work: @escaping SearchPreviewScheduler.Work) {
        lock.withLock {
            queuedWork.append(work)
        }
    }

    func runNext() throws {
        let work = lock.withLock { () -> SearchPreviewScheduler.Work? in
            guard !queuedWork.isEmpty else { return nil }
            return queuedWork.removeFirst()
        }
        try #require(work)()
    }
}

private final class SearchPreviewWorkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var activeWork = 0
    private(set) var completedWork: [Int] = []
    private(set) var maximumConcurrentWork = 0
    private(set) var observedQueuedWork: [Int] = []

    func run(_ identifier: Int) {
        begin(identifier)
        end(identifier)
    }

    func begin(_ identifier: Int) {
        _ = identifier
        lock.withLock {
            activeWork += 1
            maximumConcurrentWork = max(maximumConcurrentWork, activeWork)
        }
    }

    func end(_ identifier: Int) {
        lock.withLock {
            activeWork -= 1
            completedWork.append(identifier)
        }
    }

    func observeQueuedWork(_ count: Int) {
        lock.withLock {
            observedQueuedWork.append(count)
        }
    }
}
