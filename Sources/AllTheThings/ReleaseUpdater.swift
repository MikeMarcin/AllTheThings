import AppKit
import Foundation

@MainActor
final class ReleaseUpdater {
    static let shared = ReleaseUpdater()

    private enum DefaultsKey {
        static let automaticallyCheck = "ATTAutomaticallyCheckForUpdates"
        static let lastCheckDate = "ATTLastUpdateCheckDate"
        static let skippedReleaseTag = "ATTSkippedReleaseTag"
    }

    private enum UpdateError: LocalizedError {
        case noPublishedReleases
        case unexpectedStatusCode(Int)
        case missingResponse

        var errorDescription: String? {
            switch self {
            case .noPublishedReleases:
                "No published releases are available yet."
            case .unexpectedStatusCode(let statusCode):
                "GitHub returned HTTP \(statusCode)."
            case .missingResponse:
                "GitHub did not return an HTTP response."
            }
        }
    }

    private struct GitHubRelease: Decodable, Sendable {
        let htmlURL: URL
        let tagName: String
        let name: String?
        let draft: Bool
        let prerelease: Bool
        let publishedAt: Date?
        let assets: [GitHubAsset]

        var displayName: String {
            if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return name
            }

            return tagName
        }

        var installAsset: GitHubAsset? {
            assets.first(where: { $0.isDiskImage }) ??
                assets.first(where: { $0.isZipArchive }) ??
                assets.first(where: { $0.isDownloadableArchive })
        }

        enum CodingKeys: String, CodingKey {
            case htmlURL = "html_url"
            case tagName = "tag_name"
            case name
            case draft
            case prerelease
            case publishedAt = "published_at"
            case assets
        }
    }

    private struct GitHubAsset: Decodable, Sendable {
        let name: String
        let contentType: String?
        let browserDownloadURL: URL

        var isDiskImage: Bool {
            name.lowercased().hasSuffix(".dmg") || contentType == "application/x-apple-diskimage"
        }

        var isZipArchive: Bool {
            name.lowercased().hasSuffix(".zip") || contentType == "application/zip"
        }

        var isDownloadableArchive: Bool {
            let lowercasedName = name.lowercased()
            return lowercasedName.hasSuffix(".tar.gz") ||
                lowercasedName.hasSuffix(".tgz") ||
                contentType == "application/gzip" ||
                contentType == "application/x-gzip"
        }

        enum CodingKeys: String, CodingKey {
            case name
            case contentType = "content_type"
            case browserDownloadURL = "browser_download_url"
        }
    }

    private struct ReleaseVersion: Comparable {
        let components: [Int]

        init?(_ rawValue: String) {
            var text = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.lowercased().hasPrefix("v") {
                text.removeFirst()
            }

            var parsedComponents: [Int] = []
            for part in text.split(separator: ".") {
                let digits = part.prefix { character in
                    character.wholeNumberValue != nil
                }

                guard !digits.isEmpty, let value = Int(digits) else {
                    break
                }

                parsedComponents.append(value)
            }

            guard !parsedComponents.isEmpty else {
                return nil
            }

            components = parsedComponents
        }

        static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
            let count = max(lhs.components.count, rhs.components.count)
            for index in 0..<count {
                let left = index < lhs.components.count ? lhs.components[index] : 0
                let right = index < rhs.components.count ? rhs.components[index] : 0

                if left != right {
                    return left < right
                }
            }

            return false
        }
    }

    private nonisolated static let latestReleaseURL = URL(string: "https://api.github.com/repos/MikeMarcin/AllTheThings/releases/latest")!
    private nonisolated static let releasesURL = URL(string: "https://github.com/MikeMarcin/AllTheThings/releases")!
    private nonisolated static let checkInterval: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults
    private var activeCheck: Task<Void, Never>?

    var automaticallyChecksForUpdates: Bool {
        get {
            defaults.bool(forKey: DefaultsKey.automaticallyCheck)
        }
        set {
            defaults.set(newValue, forKey: DefaultsKey.automaticallyCheck)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            DefaultsKey.automaticallyCheck: true
        ])
    }

    func checkAutomaticallyIfNeeded(presentingWindow: NSWindow?) {
        guard automaticallyChecksForUpdates else { return }

        if let lastCheckDate = defaults.object(forKey: DefaultsKey.lastCheckDate) as? Date,
           Date().timeIntervalSince(lastCheckDate) < Self.checkInterval {
            return
        }

        checkForUpdates(presentingWindow: presentingWindow, userInitiated: false)
    }

    func checkForUpdates(presentingWindow: NSWindow?, userInitiated: Bool) {
        activeCheck?.cancel()
        activeCheck = Task { [weak self, weak presentingWindow] in
            await self?.performCheck(presentingWindow: presentingWindow, userInitiated: userInitiated)
        }
    }

    private func performCheck(presentingWindow: NSWindow?, userInitiated: Bool) async {
        do {
            let release = try await Self.fetchLatestRelease()
            guard !Task.isCancelled else { return }

            defaults.set(Date(), forKey: DefaultsKey.lastCheckDate)
            handle(release: release, presentingWindow: presentingWindow, userInitiated: userInitiated)
        } catch UpdateError.noPublishedReleases {
            guard !Task.isCancelled else { return }

            defaults.set(Date(), forKey: DefaultsKey.lastCheckDate)
            if userInitiated {
                showNoReleasesAlert(presentingWindow: presentingWindow)
            }
        } catch {
            guard !Task.isCancelled else { return }

            if userInitiated {
                showUpdateCheckFailedAlert(error: error, presentingWindow: presentingWindow)
            }
        }
    }

    private nonisolated static func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AllTheThings update checker", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateError.missingResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(GitHubRelease.self, from: data)
        case 404:
            throw UpdateError.noPublishedReleases
        default:
            throw UpdateError.unexpectedStatusCode(httpResponse.statusCode)
        }
    }

    private func handle(release: GitHubRelease, presentingWindow: NSWindow?, userInitiated: Bool) {
        guard !release.draft, !release.prerelease else {
            if userInitiated {
                showUpToDateAlert(release: release, presentingWindow: presentingWindow)
            }
            return
        }

        let currentVersion = currentBundleVersion()
        guard releaseIsNewer(release.tagName, than: currentVersion) else {
            if userInitiated {
                showUpToDateAlert(release: release, presentingWindow: presentingWindow)
            }
            return
        }

        if !userInitiated,
           defaults.string(forKey: DefaultsKey.skippedReleaseTag) == release.tagName {
            return
        }

        showUpdateAvailableAlert(
            release: release,
            currentVersion: currentVersion,
            presentingWindow: presentingWindow
        )
    }

    private func releaseIsNewer(_ releaseTag: String, than currentVersion: String) -> Bool {
        if let releaseVersion = ReleaseVersion(releaseTag),
           let current = ReleaseVersion(currentVersion) {
            return releaseVersion > current
        }

        return releaseTag != currentVersion && releaseTag != "v\(currentVersion)"
    }

    private func currentBundleVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private func showUpdateAvailableAlert(
        release: GitHubRelease,
        currentVersion: String,
        presentingWindow: NSWindow?
    ) {
        let alert = NSAlert()
        alert.messageText = "AllTheThings \(release.displayName) is available"
        alert.informativeText = "You are running \(currentVersion). Download the latest GitHub release, quit AllTheThings, then replace the app bundle with the downloaded version."

        if let asset = release.installAsset {
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "View Release")
            alert.addButton(withTitle: "Later")
            present(alert, presentingWindow: presentingWindow) { [weak self] response in
                switch response {
                case .alertFirstButtonReturn:
                    NSWorkspace.shared.open(asset.browserDownloadURL)
                case .alertSecondButtonReturn:
                    NSWorkspace.shared.open(release.htmlURL)
                default:
                    self?.defaults.set(release.tagName, forKey: DefaultsKey.skippedReleaseTag)
                }
            }
        } else {
            alert.addButton(withTitle: "View Release")
            alert.addButton(withTitle: "Later")
            present(alert, presentingWindow: presentingWindow) { [weak self] response in
                if response == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(release.htmlURL)
                } else {
                    self?.defaults.set(release.tagName, forKey: DefaultsKey.skippedReleaseTag)
                }
            }
        }
    }

    private func showNoReleasesAlert(presentingWindow: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "No releases are published yet"
        alert.informativeText = "The update checker is configured for MikeMarcin/AllTheThings, but GitHub does not currently list any published releases."
        alert.addButton(withTitle: "Open Releases")
        alert.addButton(withTitle: "OK")

        present(alert, presentingWindow: presentingWindow) { response in
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(Self.releasesURL)
            }
        }
    }

    private func showUpToDateAlert(release: GitHubRelease, presentingWindow: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "AllTheThings is up to date"
        alert.informativeText = "The latest published GitHub release is \(release.displayName)."
        alert.addButton(withTitle: "OK")
        present(alert, presentingWindow: presentingWindow)
    }

    private func showUpdateCheckFailedAlert(error: Error, presentingWindow: NSWindow?) {
        let alert = NSAlert(error: error)
        alert.messageText = "Could not check for updates"
        present(alert, presentingWindow: presentingWindow)
    }

    private func present(
        _ alert: NSAlert,
        presentingWindow: NSWindow?,
        completion: ((NSApplication.ModalResponse) -> Void)? = nil
    ) {
        if let presentingWindow, presentingWindow.isVisible {
            alert.beginSheetModal(for: presentingWindow) { response in
                completion?(response)
            }
        } else {
            let response = alert.runModal()
            completion?(response)
        }
    }
}
