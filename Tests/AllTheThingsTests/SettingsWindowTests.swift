@testable import AllTheThings
import AppKit
import ATTCore
import Foundation
import Testing

@Suite("Settings window")
struct SettingsWindowTests {
    @MainActor
    @Test("diagnostics stay on General and Full Disk Access lives in Indexed Folders")
    func diagnosticsStayOnGeneralAndFullDiskAccessLivesInIndexedFolders() throws {
        let suiteName = "AllTheThingsSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        AppSettings.registerDefaults(defaults)
        let index = FileIndex(applicationName: "AllTheThingsSettingsTests-\(UUID().uuidString)", loadsSnapshotImmediately: false)
        let controller = SettingsWindowController(defaults: defaults, index: index, reindexHandler: {})
        controller.loadWindow()
        defer {
            controller.close()
        }

        controller.selectSection(.general)
        let generalStrings = visibleStrings(in: controller.window?.contentView)
        #expect(generalStrings.contains("Diagnostics"))
        #expect(generalStrings.contains("Diagnostic detail"))
        #expect(!generalStrings.contains { $0.contains("Full Disk Access") })

        controller.selectSection(.indexedFolders)
        let indexedFolderStrings = visibleStrings(in: controller.window?.contentView)
        #expect(indexedFolderStrings.contains("Folder Access"))
        #expect(indexedFolderStrings.contains { $0.contains("Full Disk Access") })
        #expect(indexedFolderStrings.contains("Open Full Disk Access Settings"))
    }

    @MainActor
    private func visibleStrings(in view: NSView?) -> [String] {
        guard let view, !view.isHidden else { return [] }

        var strings: [String] = []
        if let textField = view as? NSTextField, !textField.stringValue.isEmpty {
            strings.append(textField.stringValue)
        }
        if let button = view as? NSButton, !button.title.isEmpty {
            strings.append(button.title)
        }

        for subview in view.subviews {
            strings.append(contentsOf: visibleStrings(in: subview))
        }
        return strings
    }
}
