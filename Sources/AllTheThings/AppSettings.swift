import Foundation

enum AppSettings {
    static let allowMultipleInstancesKey = "ATTAllowMultipleInstances"
    static let highlightSearchTextKey = "ATTHighlightSearchText"

    static func registerDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            allowMultipleInstancesKey: false,
            highlightSearchTextKey: true
        ])
    }
}
