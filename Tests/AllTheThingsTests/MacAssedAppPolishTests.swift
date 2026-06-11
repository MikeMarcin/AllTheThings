@testable import AllTheThings
import AppKit
import Carbon.HIToolbox
import Testing

@Suite("Mac-assed app polish")
struct MacAssedAppPolishTests {
    @MainActor
    @Test("main menu exposes standard Mac structure and app commands")
    func mainMenuExposesStandardMacStructureAndAppCommands() throws {
        let delegate = AppDelegate()
        delegate.configureMainMenu()

        let mainMenu = try #require(NSApp.mainMenu)
        let appMenu = try #require(mainMenu.items.first?.submenu)
        let servicesItem = try #require(item(titled: "Services", in: appMenu))
        let servicesMenu = try #require(servicesItem.submenu)
        #expect(NSApp.servicesMenu === servicesMenu)

        let insightsItem = try #require(item(titled: "Insights...", in: appMenu))
        #expect(insightsItem.keyEquivalent == "i")
        #expect(insightsItem.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control]) == [.command, .option, .shift])

        let hideOthersItem = try #require(item(titled: "Hide Others", in: appMenu))
        #expect(hideOthersItem.keyEquivalent == "h")
        #expect(hideOthersItem.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control]) == [.command, .option])
        #expect(item(titled: "Show All", in: appMenu)?.action == #selector(NSApplication.unhideAllApplications(_:)))

        let fileMenu = try #require(menu(titled: "File", in: mainMenu))
        #expect(item(titled: "Open", in: fileMenu)?.keyEquivalent == "o")
        let quickLookItem = try #require(item(titled: "Quick Look", in: fileMenu))
        #expect(quickLookItem.keyEquivalent == " ")
        #expect(quickLookItem.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control]).isEmpty)
        #expect(item(titled: "Get Info", in: fileMenu)?.keyEquivalent == "i")
        let trashItem = try #require(item(titled: "Move to Trash", in: fileMenu))
        #expect(trashItem.keyEquivalent == "\u{8}")
        #expect(trashItem.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control]) == .command)
        #expect(item(titled: "Close Window", in: fileMenu)?.keyEquivalent == "w")

        let viewMenu = try #require(menu(titled: "View", in: mainMenu))
        let matchDetailsItem = try #require(item(titled: "Show Match Details", in: viewMenu))
        #expect(matchDetailsItem.keyEquivalent == "i")
        #expect(matchDetailsItem.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control]) == [.command, .option])

        let nibMenu = try #require(item(titled: "Nib", in: viewMenu)?.submenu)
        let showNibItem = try #require(item(titled: "Show Large Nib", in: nibMenu))
        #expect(showNibItem.keyEquivalent == "n")
        #expect(showNibItem.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control]) == [.command, .option])
        let pauseNibItem = try #require(item(titled: "Pause Nib Animation", in: nibMenu))
        #expect(pauseNibItem.keyEquivalent == "n")
        #expect(pauseNibItem.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control]) == [.command, .option, .shift])
        #expect(item(titled: "Reset Nib Position", in: nibMenu)?.keyEquivalent == "")

        let windowMenu = try #require(menu(titled: "Window", in: mainMenu))
        #expect(NSApp.windowsMenu === windowMenu)
        #expect(item(titled: "Minimize", in: windowMenu)?.keyEquivalent == "m")
        #expect(item(titled: "Zoom", in: windowMenu) != nil)
        #expect(item(titled: "Bring All to Front", in: windowMenu) != nil)
    }

    @MainActor
    @Test("file table routes Finder-like keyboard actions")
    func fileTableRoutesFinderLikeKeyboardActions() throws {
        let tableView = FileTableView()
        var actions: [String] = []
        tableView.openAction = { actions.append("open") }
        tableView.quickLookAction = { actions.append("quickLook") }
        tableView.getInfoAction = { actions.append("getInfo") }
        tableView.moveToTrashAction = { actions.append("trash") }
        tableView.copyAction = { actions.append("copy") }
        tableView.copyPathAction = { actions.append("copyPath") }

        tableView.keyDown(with: try keyEvent(characters: "\r", keyCode: UInt16(kVK_Return)))
        tableView.keyDown(with: try keyEvent(characters: " ", keyCode: UInt16(kVK_Space)))
        tableView.keyDown(with: try keyEvent(characters: "o", modifiers: .command, keyCode: UInt16(kVK_ANSI_O)))
        tableView.keyDown(with: try keyEvent(characters: "i", modifiers: .command, keyCode: UInt16(kVK_ANSI_I)))
        tableView.keyDown(with: try keyEvent(characters: "\u{8}", modifiers: .command, keyCode: UInt16(kVK_Delete)))
        tableView.keyDown(with: try keyEvent(characters: "c", modifiers: .command, keyCode: UInt16(kVK_ANSI_C)))
        tableView.keyDown(with: try keyEvent(characters: "c", modifiers: [.command, .option], keyCode: UInt16(kVK_ANSI_C)))

        #expect(actions == ["open", "quickLook", "open", "getInfo", "trash", "copy", "copyPath"])
    }

    @Test("context menu target row only replaces selection when unselected")
    func contextMenuTargetRowOnlyReplacesSelectionWhenUnselected() {
        #expect(FileActionTargeting.rowIndexes(
            contextMenuTargetRow: 4,
            selectedRowIndexes: IndexSet([1, 2]),
            rowCount: 8
        ) == IndexSet(integer: 4))

        #expect(FileActionTargeting.rowIndexes(
            contextMenuTargetRow: 2,
            selectedRowIndexes: IndexSet([1, 2]),
            rowCount: 8
        ) == IndexSet([1, 2]))

        #expect(FileActionTargeting.rowIndexes(
            contextMenuTargetRow: nil,
            selectedRowIndexes: IndexSet([1, 2, 12]),
            rowCount: 8
        ) == IndexSet([1, 2]))
    }

    @MainActor
    @Test("custom controls expose keyboard activation and accessibility state")
    func customControlsExposeKeyboardActivationAndAccessibilityState() throws {
        let mascotView = ClickableMascotView()
        mascotView.accessibilityText = "Grow Nib"
        var mascotClicks = 0
        mascotView.onClick = { mascotClicks += 1 }
        mascotView.keyDown(with: try keyEvent(characters: " ", keyCode: UInt16(kVK_Space)))
        #expect(mascotClicks == 1)
        #expect(mascotView.acceptsFirstResponder)
        #expect(mascotView.accessibilityLabel() == "Grow Nib")

        let row = SidebarRow(section: .general)
        var sidebarClicks = 0
        let sidebarTarget = ClosureTarget { sidebarClicks += 1 }
        row.target = sidebarTarget
        row.action = #selector(ClosureTarget.invoke(_:))
        row.keyDown(with: try keyEvent(characters: "\r", keyCode: UInt16(kVK_Return)))
        row.isSelected = true
        #expect(sidebarClicks == 1)
        #expect(row.acceptsFirstResponder)
        #expect(row.accessibilityLabel() == "General")
        #expect(row.accessibilityValue() as? String == "Selected")
    }

    @MainActor
    private func menu(titled title: String, in mainMenu: NSMenu) -> NSMenu? {
        mainMenu.items.first { $0.submenu?.title == title }?.submenu
    }

    @MainActor
    private func item(titled title: String, in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == title }
    }

    private func keyEvent(
        characters: String,
        modifiers: NSEvent.ModifierFlags = [],
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
}

private final class ClosureTarget: NSObject {
    private let closure: () -> Void

    init(_ closure: @escaping () -> Void) {
        self.closure = closure
    }

    @objc func invoke(_ sender: Any?) {
        closure()
    }
}
