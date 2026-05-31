import AppKit
import Darwin

enum FullDiskAccessStatus: Equatable {
    case confirmed
    case notConfirmed
    case unknown

    var isConfirmed: Bool {
        self == .confirmed
    }

    var displayTitle: String {
        switch self {
        case .confirmed:
            "Confirmed"
        case .notConfirmed:
            "Not confirmed"
        case .unknown:
            "Unknown / Not confirmed"
        }
    }
}

enum FullDiskAccessController {
    private enum ProbeResult {
        case readable
        case denied
        case unavailable
    }

    static func currentStatus() -> FullDiskAccessStatus {
        let results = representativeProtectedDirectories().map(readableDirectoryStatus)

        if results.contains(.readable) {
            return .confirmed
        }

        if results.contains(.denied) {
            return .notConfirmed
        }

        return .unknown
    }

    static func protectedDefaultFoldersCovered(by roots: [URL]) -> [URL] {
        let rootPaths = roots.map { $0.standardizedFileURL.path }

        return protectedDefaultFolders().filter { protectedFolder in
            let protectedPath = protectedFolder.standardizedFileURL.path
            return rootPaths.contains { indexedPath in
                pathsOverlap(indexedPath, protectedPath)
            }
        }
    }

    @MainActor
    static func openSystemSettings() {
        let urlStrings = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ]

        for urlString in urlStrings {
            guard let url = URL(string: urlString) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }

        if let settingsURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    private static func representativeProtectedDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Safari", isDirectory: true),
            home.appendingPathComponent("Library/Mail", isDirectory: true),
            home.appendingPathComponent("Library/Messages", isDirectory: true),
            home.appendingPathComponent("Library/Calendars", isDirectory: true)
        ]
    }

    private static func protectedDefaultFolders() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true)
        ]
    }

    private static func readableDirectoryStatus(at url: URL) -> ProbeResult {
        let path = url.path
        var statInfo = stat()
        errno = 0

        let statResult = path.withCString { stat($0, &statInfo) }
        guard statResult == 0 else {
            return isPermissionDenied(errno) ? .denied : .unavailable
        }

        guard (statInfo.st_mode & S_IFMT) == S_IFDIR else {
            return .unavailable
        }

        errno = 0
        guard path.withCString({ access($0, R_OK | X_OK) }) == 0 else {
            return isPermissionDenied(errno) ? .denied : .unavailable
        }

        return .readable
    }

    private static func isPermissionDenied(_ errorNumber: Int32) -> Bool {
        errorNumber == EACCES || errorNumber == EPERM
    }

    private static func pathsOverlap(_ firstPath: String, _ secondPath: String) -> Bool {
        firstPath == secondPath
            || firstPath.hasPrefix(secondPath + "/")
            || secondPath.hasPrefix(firstPath + "/")
    }
}
