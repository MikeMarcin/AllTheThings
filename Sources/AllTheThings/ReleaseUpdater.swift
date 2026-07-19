import AppKit
import ATTCore
import Darwin
import Foundation
import Security

@MainActor
final class ReleaseUpdater {
    static let shared = ReleaseUpdater()

    private enum DefaultsKey {
        static let automaticallyCheck = "ATTAutomaticallyCheckForUpdates"
        static let lastCheckDate = "ATTLastUpdateCheckDate"
        static let skippedReleaseTag = "ATTSkippedReleaseTag"
        static let installStartedAt = "ATTUpdateInstallStartedAt"
        static let installTargetVersion = "ATTUpdateInstallTargetVersion"
        static let installAssetName = "ATTUpdateInstallAssetName"
    }

    private enum UpdateError: LocalizedError {
        case noPublishedReleases
        case unexpectedStatusCode(Int)
        case missingResponse
        case unsupportedAsset(String)
        case appBundleNotFound
        case missingBundleIdentifier(URL)
        case mismatchedBundleIdentifier(expected: String, actual: String)
        case downloadedAppIsNotNewer(downloaded: String, current: String)
        case downloadFailed(Int)
        case commandFailed(command: String, status: Int32, output: String)
        case codeSignatureInvalid(URL, OSStatus)
        case installPathNotWritable(URL)
        case helperLaunchFailed(Error)

        var errorDescription: String? {
            switch self {
            case .noPublishedReleases:
                return "No published releases are available yet."
            case .unexpectedStatusCode(let statusCode):
                return "GitHub returned HTTP \(statusCode)."
            case .missingResponse:
                return "GitHub did not return an HTTP response."
            case .unsupportedAsset(let name):
                return "AllTheThings cannot install this release asset: \(name)."
            case .appBundleNotFound:
                return "The downloaded release did not contain an app bundle."
            case .missingBundleIdentifier(let url):
                return "The downloaded app is missing a bundle identifier: \(url.lastPathComponent)."
            case let .mismatchedBundleIdentifier(expected, actual):
                return "The downloaded app has bundle identifier \(actual), but expected \(expected)."
            case let .downloadedAppIsNotNewer(downloaded, current):
                return "The downloaded app is version \(downloaded), which is not newer than \(current)."
            case .downloadFailed(let statusCode):
                return "The update download failed with HTTP \(statusCode)."
            case let .commandFailed(command, status, output):
                let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if detail.isEmpty {
                    return "\(command) failed with exit code \(status)."
                }

                return "\(command) failed with exit code \(status): \(detail)"
            case let .codeSignatureInvalid(url, status):
                return "The downloaded app failed code signature verification: \(url.lastPathComponent) (\(ReleaseUpdater.securityErrorDescription(status)))."
            case .installPathNotWritable(let url):
                return "AllTheThings cannot replace the app at \(url.path). Move it to a writable folder, such as /Applications for your user account, then try again."
            case .helperLaunchFailed(let error):
                return "Could not start the installer: \(error.localizedDescription)"
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
            assets.first(where: { $0.isZipArchive }) ??
                assets.first(where: { $0.isDiskImage }) ??
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

        private var lowercasedName: String {
            name.lowercased()
        }

        var isDiskImage: Bool {
            lowercasedName.hasSuffix(".dmg") || contentType == "application/x-apple-diskimage"
        }

        var isZipArchive: Bool {
            lowercasedName.hasSuffix(".zip") ||
                contentType == "application/zip" ||
                contentType == "application/x-zip-compressed"
        }

        var isDownloadableArchive: Bool {
            lowercasedName.hasSuffix(".tar.gz") ||
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

    private struct DownloadedAsset: Sendable {
        let archiveURL: URL
        let workDirectory: URL
    }

    private struct PreparedUpdate: Sendable {
        let appURL: URL
        let workDirectory: URL
    }

    private struct MountedDiskImage: Sendable {
        let deviceIdentifier: String?
        let mountPoint: URL

        var detachTarget: String {
            deviceIdentifier ?? mountPoint.path
        }
    }

    private struct CommandResult: Sendable {
        let standardOutput: String
        let standardError: String

        var combinedOutput: String {
            [standardOutput, standardError].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    private nonisolated static let latestReleaseURL = URL(string: "https://api.github.com/repos/MikeMarcin/AllTheThings/releases/latest")!
    private nonisolated static let releasesURL = URL(string: "https://github.com/MikeMarcin/AllTheThings/releases")!
    private nonisolated static let checkInterval: TimeInterval = 24 * 60 * 60
    private nonisolated static let appName = "AllTheThings"
    private nonisolated static let staleUpdateMinimumAge: TimeInterval = 60 * 60

    private let defaults: UserDefaults
    private var activeCheck: Task<Void, Never>?
    private var activeInstall: Task<Void, Never>?
    private var progressWindowController: UpdateProgressWindowController?

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

    func performLaunchMaintenance() {
        recordCompletedInstallIfNeeded()
        Task.detached(priority: .utility) {
            Self.cleanupStaleUpdateMounts()
        }
    }

    private func recordCompletedInstallIfNeeded() {
        guard let startedAt = defaults.object(forKey: DefaultsKey.installStartedAt) as? Date else {
            return
        }

        let targetVersion = defaults.string(forKey: DefaultsKey.installTargetVersion) ?? "unknown"
        let assetName = defaults.string(forKey: DefaultsKey.installAssetName) ?? "unknown"
        let currentVersion = currentBundleVersion()
        var fields: [String: DiagnosticLogFieldValue] = [
            "assetName": .publicString(assetName),
            "targetVersion": .publicString(targetVersion),
            "currentVersion": .publicString(currentVersion),
            "targetReached": .publicBool(currentVersion == targetVersion),
            "elapsed": .publicDouble(max(0, Date().timeIntervalSince(startedAt)))
        ]

        if let receipt = Self.loadInstallReceipt() {
            if let method = receipt["installMethod"] {
                fields["installMethod"] = .publicString(method)
            }
            if let duration = receipt["replacementDuration"].flatMap(Double.init) {
                fields["replacementDuration"] = .publicDouble(duration)
            }
        }

        DiagnosticLogger.shared.log(
            category: "updates",
            event: "updates.installCompleted",
            fields: fields
        )
        clearPendingInstallTelemetry()
        try? FileManager.default.removeItem(at: Self.installReceiptURL())
    }

    private func clearPendingInstallTelemetry() {
        defaults.removeObject(forKey: DefaultsKey.installStartedAt)
        defaults.removeObject(forKey: DefaultsKey.installTargetVersion)
        defaults.removeObject(forKey: DefaultsKey.installAssetName)
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
        DiagnosticLogger.shared.log(
            category: "updates",
            event: "updates.checkRequested",
            fields: [
                "userInitiated": .publicBool(userInitiated)
            ]
        )
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
            DiagnosticLogger.shared.log(
                category: "updates",
                event: "updates.checkFinished",
                fields: [
                    "userInitiated": .publicBool(userInitiated),
                    "tagName": .publicString(release.tagName),
                    "assetCount": .publicInt(release.assets.count),
                    "hasInstallAsset": .publicBool(release.installAsset != nil)
                ]
            )
            handle(release: release, presentingWindow: presentingWindow, userInitiated: userInitiated)
        } catch UpdateError.noPublishedReleases {
            guard !Task.isCancelled else { return }

            defaults.set(Date(), forKey: DefaultsKey.lastCheckDate)
            DiagnosticLogger.shared.log(
                level: .warning,
                category: "updates",
                event: "updates.noPublishedReleases",
                fields: [
                    "userInitiated": .publicBool(userInitiated)
                ]
            )
            if userInitiated {
                showNoReleasesAlert(presentingWindow: presentingWindow)
            }
        } catch {
            guard !Task.isCancelled else { return }

            DiagnosticLogger.shared.log(
                level: .error,
                category: "updates",
                event: "updates.checkFailed",
                fields: [
                    "userInitiated": .publicBool(userInitiated),
                    "error": .errorText(error.localizedDescription)
                ]
            )
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
        guard Self.releaseIsNewer(release.tagName, than: currentVersion) else {
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

    private nonisolated static func releaseIsNewer(_ releaseTag: String, than currentVersion: String) -> Bool {
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

        guard let asset = release.installAsset else {
            alert.informativeText = "You are running \(currentVersion). This release does not include an installable app archive."
            alert.addButton(withTitle: "View Release")
            alert.addButton(withTitle: "Later")
            present(alert, presentingWindow: presentingWindow) { [weak self] response in
                if response == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(release.htmlURL)
                } else {
                    self?.defaults.set(release.tagName, forKey: DefaultsKey.skippedReleaseTag)
                }
            }
            return
        }

        alert.informativeText = "You are running \(currentVersion). AllTheThings will download the update, replace this app, and relaunch."
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "View Release")
        alert.addButton(withTitle: "Later")
        present(alert, presentingWindow: presentingWindow) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.install(release: release, asset: asset, presentingWindow: presentingWindow)
            case .alertSecondButtonReturn:
                NSWorkspace.shared.open(release.htmlURL)
            default:
                self?.defaults.set(release.tagName, forKey: DefaultsKey.skippedReleaseTag)
            }
        }
    }

    private func install(release: GitHubRelease, asset: GitHubAsset, presentingWindow: NSWindow?) {
        activeCheck?.cancel()
        activeInstall?.cancel()

        let progressController = UpdateProgressWindowController()
        progressController.show(attachedTo: presentingWindow)
        progressWindowController = progressController

        activeInstall = Task { [weak self, weak presentingWindow] in
            guard let self else { return }

            do {
                try await self.performInstall(asset: asset)
            } catch is CancellationError {
                self.progressWindowController?.closeProgress()
                self.progressWindowController = nil
            } catch {
                self.progressWindowController?.closeProgress()
                self.progressWindowController = nil
                self.showUpdateInstallFailedAlert(
                    error: error,
                    release: release,
                    presentingWindow: presentingWindow
                )
            }

            self.activeInstall = nil
        }
    }

    private func performInstall(asset: GitHubAsset) async throws {
        var workDirectory: URL?
        var shouldCleanUp = true
        let installStartedAt = Date()

        DiagnosticLogger.shared.log(
            category: "updates",
            event: "updates.installStarted",
            fields: [
                "assetName": .publicString(asset.name),
                "assetType": .publicString(Self.assetTypeName(asset))
            ]
        )

        do {
            progressWindowController?.updateStatus("Downloading \(asset.name)...")
            let downloadStartedAt = Date()
            let downloaded = try await Self.download(asset: asset)
            workDirectory = downloaded.workDirectory
            logInstallPhase("download", startedAt: downloadStartedAt, asset: asset)

            try Task.checkCancellation()
            progressWindowController?.updateStatus("Preparing update...")
            let preparationStartedAt = Date()
            let prepared = try await Task.detached(priority: .userInitiated) {
                try Self.prepareDownloadedApp(downloaded: downloaded, asset: asset)
            }.value
            logInstallPhase("preparation", startedAt: preparationStartedAt, asset: asset)

            try Task.checkCancellation()
            progressWindowController?.updateStatus("Validating update...")
            let currentAppURL = Bundle.main.bundleURL
            let currentVersion = currentBundleVersion()
            guard let currentBundleIdentifier = Bundle.main.bundleIdentifier else {
                throw UpdateError.missingBundleIdentifier(currentAppURL)
            }

            let validationStartedAt = Date()
            let downloadedVersion = try await Task.detached(priority: .userInitiated) {
                try Self.validatePreparedApp(
                    at: prepared.appURL,
                    expectedBundleIdentifier: currentBundleIdentifier,
                    currentAppURL: currentAppURL,
                    currentVersion: currentVersion
                )
            }.value
            logInstallPhase("validation", startedAt: validationStartedAt, asset: asset)

            try Self.preflightInstallPermissions(currentAppURL: currentAppURL)

            try Task.checkCancellation()
            progressWindowController?.updateStatus("Installing and restarting...")
            let helperURL = try Self.writeInstallHelper(
                preparedAppURL: prepared.appURL,
                currentAppURL: currentAppURL,
                workDirectory: prepared.workDirectory,
                receiptURL: Self.installReceiptURL()
            )
            defaults.set(installStartedAt, forKey: DefaultsKey.installStartedAt)
            defaults.set(downloadedVersion, forKey: DefaultsKey.installTargetVersion)
            defaults.set(asset.name, forKey: DefaultsKey.installAssetName)
            defaults.synchronize()
            let helperStartedAt = Date()
            do {
                try Self.launchInstallHelper(at: helperURL)
            } catch {
                clearPendingInstallTelemetry()
                throw error
            }
            logInstallPhase("helperLaunch", startedAt: helperStartedAt, asset: asset)

            shouldCleanUp = false
            defaults.removeObject(forKey: DefaultsKey.skippedReleaseTag)
            defaults.synchronize()
            progressWindowController?.closeProgress()
            progressWindowController = nil
            DiagnosticLogger.shared.flush()
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            DiagnosticLogger.shared.log(
                level: .error,
                category: "updates",
                event: "updates.installFailed",
                fields: [
                    "assetName": .publicString(asset.name),
                    "assetType": .publicString(Self.assetTypeName(asset)),
                    "elapsed": .publicDouble(max(0, Date().timeIntervalSince(installStartedAt))),
                    "error": .errorText(error.localizedDescription)
                ]
            )
            if shouldCleanUp, let workDirectory {
                try? FileManager.default.removeItem(at: workDirectory)
            }
            throw error
        }
    }

    private func logInstallPhase(_ phase: String, startedAt: Date, asset: GitHubAsset) {
        DiagnosticLogger.shared.log(
            category: "updates",
            event: "updates.installPhaseCompleted",
            fields: [
                "phase": .publicString(phase),
                "assetName": .publicString(asset.name),
                "assetType": .publicString(Self.assetTypeName(asset)),
                "duration": .publicDouble(max(0, Date().timeIntervalSince(startedAt)))
            ]
        )
    }

    private nonisolated static func download(asset: GitHubAsset) async throws -> DownloadedAsset {
        try await download(asset: asset) { request in
            try await URLSession.shared.download(for: request)
        }
    }

    private nonisolated static func download(
        asset: GitHubAsset,
        using downloadHandler: (URLRequest) async throws -> (URL, URLResponse)
    ) async throws -> DownloadedAsset {
        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("\(appName)-Update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        do {
            var request = URLRequest(url: asset.browserDownloadURL)
            request.setValue("AllTheThings update installer", forHTTPHeaderField: "User-Agent")

            let (temporaryURL, response) = try await downloadHandler(request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                throw UpdateError.downloadFailed(httpResponse.statusCode)
            }

            let destination = workDirectory.appendingPathComponent(sanitizedFileName(asset.name), isDirectory: false)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: temporaryURL, to: destination)

            return DownloadedAsset(archiveURL: destination, workDirectory: workDirectory)
        } catch {
            try? fileManager.removeItem(at: workDirectory)
            throw error
        }
    }

    private nonisolated static func prepareDownloadedApp(
        downloaded: DownloadedAsset,
        asset: GitHubAsset
    ) throws -> PreparedUpdate {
        if asset.isZipArchive {
            return try prepareZipUpdate(downloaded: downloaded)
        }

        if asset.isDiskImage {
            return try prepareDiskImageUpdate(downloaded: downloaded)
        }

        if asset.isDownloadableArchive {
            return try prepareTarUpdate(downloaded: downloaded)
        }

        throw UpdateError.unsupportedAsset(asset.name)
    }

    private nonisolated static func prepareZipUpdate(downloaded: DownloadedAsset) throws -> PreparedUpdate {
        let extractionDirectory = downloaded.workDirectory.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)
        _ = try runCommand("/usr/bin/ditto", arguments: [
            "-x",
            "-k",
            downloaded.archiveURL.path,
            extractionDirectory.path
        ])

        let appURL = try findAppBundle(in: extractionDirectory)
        return PreparedUpdate(appURL: appURL, workDirectory: downloaded.workDirectory)
    }

    private nonisolated static func prepareTarUpdate(downloaded: DownloadedAsset) throws -> PreparedUpdate {
        let extractionDirectory = downloaded.workDirectory.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)
        _ = try runCommand("/usr/bin/tar", arguments: [
            "-xzf",
            downloaded.archiveURL.path,
            "-C",
            extractionDirectory.path
        ])

        let appURL = try findAppBundle(in: extractionDirectory)
        return PreparedUpdate(appURL: appURL, workDirectory: downloaded.workDirectory)
    }

    private nonisolated static func prepareDiskImageUpdate(downloaded: DownloadedAsset) throws -> PreparedUpdate {
        let fileManager = FileManager.default
        let mountPoint = downloaded.workDirectory.appendingPathComponent("mount", isDirectory: true)
        let payloadDirectory = downloaded.workDirectory.appendingPathComponent("payload", isDirectory: true)
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)

        let attachResult = try runCommandResult("/usr/bin/hdiutil", arguments: [
            "attach",
            downloaded.archiveURL.path,
            "-nobrowse",
            "-readonly",
            "-plist",
            "-mountpoint",
            mountPoint.path
        ])
        let mountedImage = mountedDiskImage(
            fromAttachPlist: attachResult.standardOutput,
            fallbackMountPoint: mountPoint
        )
        defer {
            _ = detachDiskImageBestEffort(mountedImage)
        }

        let mountedAppURL = try findAppBundle(in: mountPoint)
        let copiedAppURL = payloadDirectory.appendingPathComponent(mountedAppURL.lastPathComponent, isDirectory: true)
        _ = try runCommand("/usr/bin/ditto", arguments: [
            mountedAppURL.path,
            copiedAppURL.path
        ])

        return PreparedUpdate(appURL: copiedAppURL, workDirectory: downloaded.workDirectory)
    }

    private nonisolated static func validatePreparedApp(
        at appURL: URL,
        expectedBundleIdentifier: String,
        currentAppURL: URL,
        currentVersion: String
    ) throws -> String {
        guard let bundle = Bundle(url: appURL) else {
            throw UpdateError.appBundleNotFound
        }

        guard let bundleIdentifier = bundle.bundleIdentifier else {
            throw UpdateError.missingBundleIdentifier(appURL)
        }

        guard bundleIdentifier == expectedBundleIdentifier else {
            throw UpdateError.mismatchedBundleIdentifier(
                expected: expectedBundleIdentifier,
                actual: bundleIdentifier
            )
        }

        let downloadedVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        guard releaseIsNewer(downloadedVersion, than: currentVersion) else {
            throw UpdateError.downloadedAppIsNotNewer(
                downloaded: downloadedVersion,
                current: currentVersion
            )
        }

        try validateCodeSignature(candidateURL: appURL, currentAppURL: currentAppURL)
        return downloadedVersion
    }

    private nonisolated static func validateCodeSignature(candidateURL: URL, currentAppURL: URL) throws {
        let candidateCode = try staticCode(for: candidateURL)
        let currentCode = try staticCode(for: currentAppURL)
        let strictFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)

        var requirement: SecRequirement?
        var status = SecCodeCopyDesignatedRequirement(currentCode, SecCSFlags(), &requirement)
        guard status == errSecSuccess, let requirement else {
            throw UpdateError.codeSignatureInvalid(currentAppURL, status)
        }

        status = SecStaticCodeCheckValidity(candidateCode, strictFlags, requirement)
        guard status == errSecSuccess else {
            throw UpdateError.codeSignatureInvalid(candidateURL, status)
        }
    }

    private nonisolated static func staticCode(for url: URL) throws -> SecStaticCode {
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
        guard status == errSecSuccess, let staticCode else {
            throw UpdateError.codeSignatureInvalid(url, status)
        }

        return staticCode
    }

    private nonisolated static func preflightInstallPermissions(currentAppURL: URL) throws {
        let fileManager = FileManager.default
        let parentURL = currentAppURL.deletingLastPathComponent()

        guard fileManager.isWritableFile(atPath: parentURL.path) else {
            throw UpdateError.installPathNotWritable(parentURL)
        }

        if fileManager.fileExists(atPath: currentAppURL.path),
           !fileManager.isWritableFile(atPath: currentAppURL.path) {
            throw UpdateError.installPathNotWritable(currentAppURL)
        }
    }

    private nonisolated static func writeInstallHelper(
        preparedAppURL: URL,
        currentAppURL: URL,
        workDirectory: URL,
        receiptURL: URL
    ) throws -> URL {
        let helperURL = workDirectory.appendingPathComponent("install-update.zsh", isDirectory: false)
        let processIdentifier = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/zsh
        set -euo pipefail

        app_path=\(shellQuoted(currentAppURL.path))
        new_app=\(shellQuoted(preparedAppURL.path))
        work_dir=\(shellQuoted(workDirectory.path))
        receipt_path=\(shellQuoted(receiptURL.path))
        receipt_dir=\(shellQuoted(receiptURL.deletingLastPathComponent().path))
        pid=\(processIdentifier)
        backup_path="${app_path}.previous-update-$(date +%Y%m%d%H%M%S)"
        log_path="${work_dir}/install.log"
        wait_deadline=$(( $(/bin/date +%s) + 15 ))

        {
            echo "Waiting for AllTheThings process ${pid} to exit"
            while /bin/kill -0 "${pid}" 2>/dev/null; do
                if (( $(/bin/date +%s) >= wait_deadline )); then
                    echo "Process ${pid} did not exit; sending SIGTERM"
                    /bin/kill "${pid}" 2>/dev/null || true
                    /bin/sleep 2

                    if /bin/kill -0 "${pid}" 2>/dev/null; then
                        echo "Process ${pid} did not terminate; sending SIGKILL"
                        /bin/kill -9 "${pid}" 2>/dev/null || true
                    fi
                fi

                /bin/sleep 0.2
            done

            if [[ ! -d "${new_app}" ]]; then
                echo "Updated app is missing: ${new_app}"
                exit 1
            fi

            if [[ -e "${backup_path}" ]]; then
                /bin/rm -rf "${backup_path}"
            fi

            if [[ -e "${app_path}" ]]; then
                /bin/mv "${app_path}" "${backup_path}"
            fi

            replacement_started=$(/bin/date +%s)
            install_method="copy"
            installed=0
            new_device=$(/usr/bin/stat -f %d "${new_app}" 2>/dev/null || true)
            target_device=$(/usr/bin/stat -f %d "${app_path:h}" 2>/dev/null || true)
            if [[ -n "${new_device}" && "${new_device}" == "${target_device}" ]]; then
                if /bin/mv "${new_app}" "${app_path}"; then
                    install_method="move"
                    installed=1
                fi
            fi

            if (( installed == 0 )); then
                /bin/rm -rf "${app_path}"
                if /usr/bin/ditto "${new_app}" "${app_path}"; then
                    installed=1
                fi
            fi

            if (( installed == 0 )); then
                /bin/rm -rf "${app_path}"
                if [[ -d "${backup_path}" ]]; then
                    /bin/mv "${backup_path}" "${app_path}"
                    /usr/bin/open "${app_path}" || true
                fi
                exit 1
            fi

            /usr/bin/xattr -dr com.apple.quarantine "${app_path}" 2>/dev/null || true
            replacement_finished=$(/bin/date +%s)
            /bin/rm -rf "${backup_path}"
            receipt_tmp="${receipt_path}.tmp.$$"
            /bin/mkdir -p "${receipt_dir}" 2>/dev/null || true
            {
                print -r -- "installMethod=${install_method}"
                print -r -- "replacementDuration=$(( replacement_finished - replacement_started ))"
            } > "${receipt_tmp}" 2>/dev/null && /bin/mv "${receipt_tmp}" "${receipt_path}" 2>/dev/null || true
            /usr/bin/open "${app_path}"
            /bin/rm -rf "${work_dir}"
        } >> "${log_path}" 2>&1
        """

        try script.write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)
        return helperURL
    }

    private nonisolated static func launchInstallHelper(at helperURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [helperURL.path]

        do {
            try process.run()
        } catch {
            throw UpdateError.helperLaunchFailed(error)
        }
    }

    private nonisolated static func findAppBundle(in directory: URL) throws -> URL {
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw UpdateError.appBundleNotFound
        }

        for case let url as URL in enumerator where url.pathExtension == "app" {
            return url
        }

        throw UpdateError.appBundleNotFound
    }

    private nonisolated static func assetTypeName(_ asset: GitHubAsset) -> String {
        if asset.isZipArchive { return "zip" }
        if asset.isDiskImage { return "dmg" }
        return "archive"
    }

    private nonisolated static func mountedDiskImage(
        fromAttachPlist plist: String,
        fallbackMountPoint: URL
    ) -> MountedDiskImage {
        let entities = propertyListDictionary(from: plist)?["system-entities"] as? [[String: Any]] ?? []
        let mountedEntity = entities.first { entity in
            (entity["mount-point"] as? String) == fallbackMountPoint.path
        } ?? entities.first { $0["mount-point"] != nil }
        let mountPoint = (mountedEntity?["mount-point"] as? String)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fallbackMountPoint
        return MountedDiskImage(
            deviceIdentifier: mountedEntity?["dev-entry"] as? String,
            mountPoint: mountPoint
        )
    }

    private nonisolated static func mountedDiskImages(fromInfoPlist plist: String) -> [MountedDiskImage] {
        guard let images = propertyListDictionary(from: plist)?["images"] as? [[String: Any]] else {
            return []
        }

        return images.flatMap { image -> [MountedDiskImage] in
            guard let entities = image["system-entities"] as? [[String: Any]] else { return [] }
            return entities.compactMap { entity in
                guard let mountPoint = entity["mount-point"] as? String else { return nil }
                return MountedDiskImage(
                    deviceIdentifier: entity["dev-entry"] as? String,
                    mountPoint: URL(fileURLWithPath: mountPoint, isDirectory: true)
                )
            }
        }
    }

    private nonisolated static func propertyListDictionary(from plist: String) -> [String: Any]? {
        guard
            let data = plist.data(using: .utf8),
            let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else {
            return nil
        }
        return propertyList as? [String: Any]
    }

    @discardableResult
    private nonisolated static func detachDiskImageBestEffort(
        _ image: MountedDiskImage,
        retryDelays: [TimeInterval] = [0, 0.25, 1],
        commandRunner: (String, [String]) throws -> Void = { executable, arguments in
            _ = try runCommand(executable, arguments: arguments)
        },
        sleeper: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> Bool {
        var lastError: Error?

        for delay in retryDelays {
            if delay > 0 {
                sleeper(delay)
            }
            do {
                try commandRunner("/usr/bin/hdiutil", [
                    "detach",
                    image.detachTarget,
                    "-quiet"
                ])
                return true
            } catch {
                lastError = error
            }
        }

        DiagnosticLogger.shared.log(
            level: .warning,
            category: "updates",
            event: "updates.diskImageDetachFailed",
            fields: [
                "attemptCount": .publicInt(retryDelays.count),
                "error": .errorText(lastError?.localizedDescription ?? "Unknown detach error")
            ],
            diagnosticFields: [
                "mountPoint": .path(image.mountPoint.path)
            ]
        )
        return false
    }

    private nonisolated static func cleanupStaleUpdateMounts(
        fileManager: FileManager = .default,
        now: Date = Date()
    ) {
        guard let result = try? runCommandResult("/usr/bin/hdiutil", arguments: ["info", "-plist"]) else {
            return
        }

        var handledTargets = Set<String>()
        for image in mountedDiskImages(fromInfoPlist: result.standardOutput) {
            guard handledTargets.insert(image.detachTarget).inserted else { continue }
            guard let workDirectory = staleUpdateWorkDirectory(
                for: image.mountPoint,
                fileManager: fileManager,
                now: now
            ) else {
                continue
            }
            guard detachDiskImageBestEffort(image) else { continue }
            guard !isMounted(image.mountPoint) else { continue }

            try? fileManager.removeItem(at: workDirectory)
            DiagnosticLogger.shared.log(
                category: "updates",
                event: "updates.staleDiskImageDetached",
                diagnosticFields: [
                    "mountPoint": .path(image.mountPoint.path)
                ]
            )
        }
    }

    private nonisolated static func staleUpdateWorkDirectory(
        for mountPoint: URL,
        fileManager: FileManager,
        now: Date
    ) -> URL? {
        let temporaryDirectory = fileManager.temporaryDirectory.standardizedFileURL
        let path = mountPoint.standardizedFileURL.path
        let temporaryPrefix = temporaryDirectory.path.hasSuffix("/")
            ? temporaryDirectory.path
            : temporaryDirectory.path + "/"
        guard !path.hasPrefix("/Volumes/"), path.hasPrefix(temporaryPrefix) else { return nil }

        let relativePath = String(path.dropFirst(temporaryPrefix.count))
        guard let directoryName = relativePath.split(separator: "/").first,
              directoryName.hasPrefix("\(appName)-Update-") else {
            return nil
        }

        let workDirectory = temporaryDirectory.appendingPathComponent(String(directoryName), isDirectory: true)
        let values = try? workDirectory.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let lastTouched = [values?.creationDate, values?.contentModificationDate].compactMap { $0 }.max()
        guard let lastTouched,
              now.timeIntervalSince(lastTouched) >= staleUpdateMinimumAge else {
            return nil
        }
        return workDirectory
    }

    private nonisolated static func isMounted(_ mountPoint: URL) -> Bool {
        guard let result = try? runCommandResult("/usr/bin/hdiutil", arguments: ["info", "-plist"]) else {
            return true
        }
        return mountedDiskImages(fromInfoPlist: result.standardOutput).contains {
            $0.mountPoint.standardizedFileURL == mountPoint.standardizedFileURL
        }
    }

    private nonisolated static func installReceiptURL(fileManager: FileManager = .default) -> URL {
        let supportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return supportRoot
            .appendingPathComponent(appName, isDirectory: true)
            .appendingPathComponent("update-install-receipt.txt", isDirectory: false)
    }

    private nonisolated static func loadInstallReceipt(fileManager: FileManager = .default) -> [String: String]? {
        guard let contents = try? String(contentsOf: installReceiptURL(fileManager: fileManager), encoding: .utf8) else {
            return nil
        }

        return contents.split(whereSeparator: \.isNewline).reduce(into: [:]) { fields, line in
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return }
            fields[pair[0]] = pair[1]
        }
    }

    @discardableResult
    private nonisolated static func runCommand(_ executablePath: String, arguments: [String]) throws -> String {
        try runCommandResult(executablePath, arguments: arguments).combinedOutput
    }

    private nonisolated static func runCommandResult(
        _ executablePath: String,
        arguments: [String]
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputBuffer = CommandOutputBuffer()
        let errorBuffer = CommandOutputBuffer()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            outputBuffer.append(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            errorBuffer.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        process.waitUntilExit()

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        outputBuffer.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
        errorBuffer.append(errorPipe.fileHandleForReading.readDataToEndOfFile())

        let output = outputBuffer.string()
        let error = errorBuffer.string()
        let result = CommandResult(standardOutput: output, standardError: error)
        guard process.terminationStatus == 0 else {
            throw UpdateError.commandFailed(
                command: URL(fileURLWithPath: executablePath).lastPathComponent,
                status: process.terminationStatus,
                output: result.combinedOutput
            )
        }

        return result
    }

    private final class CommandOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.withLock {
                data.append(chunk)
            }
        }

        func string() -> String {
            let snapshot = lock.withLock { data }
            return String(data: snapshot, encoding: .utf8) ?? ""
        }
    }

#if DEBUG
    nonisolated static func preferredAssetNameForTesting(_ assetNames: [String]) -> String? {
        let assets = assetNames.map { name in
            GitHubAsset(
                name: name,
                contentType: nil,
                browserDownloadURL: URL(string: "https://example.test/\(name)")!
            )
        }
        return GitHubRelease(
            htmlURL: URL(string: "https://example.test/release")!,
            tagName: "1.0.0",
            name: nil,
            draft: false,
            prerelease: false,
            publishedAt: nil,
            assets: assets
        ).installAsset?.name
    }

    nonisolated static func mountedDiskImageForTesting(
        attachPlist: String,
        fallbackMountPoint: URL
    ) -> (deviceIdentifier: String?, mountPoint: URL) {
        let image = mountedDiskImage(fromAttachPlist: attachPlist, fallbackMountPoint: fallbackMountPoint)
        return (image.deviceIdentifier, image.mountPoint)
    }

    nonisolated static func detachDiskImageForTesting(
        deviceIdentifier: String?,
        mountPoint: URL,
        failuresBeforeSuccess: Int
    ) -> (succeeded: Bool, arguments: [[String]]) {
        var arguments: [[String]] = []
        let image = MountedDiskImage(deviceIdentifier: deviceIdentifier, mountPoint: mountPoint)
        let succeeded = detachDiskImageBestEffort(
            image,
            retryDelays: [0, 0, 0],
            commandRunner: { _, commandArguments in
                arguments.append(commandArguments)
                if arguments.count <= failuresBeforeSuccess {
                    throw CocoaError(.fileWriteUnknown)
                }
            },
            sleeper: { _ in }
        )
        return (succeeded, arguments)
    }

    nonisolated static func staleUpdateWorkDirectoryForTesting(
        mountPoint: URL,
        now: Date = Date()
    ) -> URL? {
        staleUpdateWorkDirectory(for: mountPoint, fileManager: .default, now: now)
    }

    nonisolated static func installHelperContentsForTesting(
        preparedAppURL: URL,
        currentAppURL: URL,
        workDirectory: URL
    ) throws -> String {
        let helperURL = try writeInstallHelper(
            preparedAppURL: preparedAppURL,
            currentAppURL: currentAppURL,
            workDirectory: workDirectory,
            receiptURL: workDirectory.appendingPathComponent("receipt.txt")
        )
        return try String(contentsOf: helperURL, encoding: .utf8)
    }

    nonisolated static func runCommandForTesting(_ executablePath: String, arguments: [String]) throws -> String {
        try runCommand(executablePath, arguments: arguments)
    }

    nonisolated static func downloadForTesting(
        assetName: String,
        downloadURL: URL,
        contentType: String? = nil,
        using downloadHandler: (URLRequest) async throws -> (URL, URLResponse)
    ) async throws -> URL {
        let downloaded = try await download(
            asset: GitHubAsset(
                name: assetName,
                contentType: contentType,
                browserDownloadURL: downloadURL
            ),
            using: downloadHandler
        )
        return downloaded.workDirectory
    }
#endif

    private nonisolated static func sanitizedFileName(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:")
        let parts = name.components(separatedBy: invalidCharacters)
        let sanitized = parts.joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "update-archive" : sanitized
    }

    private nonisolated static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private nonisolated static func securityErrorDescription(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "\(message) \(status)"
        }

        return "OSStatus \(status)"
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

    private func showUpdateInstallFailedAlert(
        error: Error,
        release: GitHubRelease,
        presentingWindow: NSWindow?
    ) {
        let alert = NSAlert(error: error)
        alert.messageText = "Could not install update"
        alert.addButton(withTitle: "View Release")
        alert.addButton(withTitle: "OK")
        present(alert, presentingWindow: presentingWindow) { response in
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(release.htmlURL)
            }
        }
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

@MainActor
private final class UpdateProgressWindowController: NSWindowController {
    private let statusLabel: NSTextField

    init() {
        statusLabel = NSTextField(labelWithString: "Preparing update...")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2

        let progressIndicator = NSProgressIndicator()
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .large
        progressIndicator.startAnimation(nil)

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(progressIndicator)
        contentView.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            progressIndicator.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            progressIndicator.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor, constant: 18),
            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            statusLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
        ])

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Updating AllTheThings"
        window.contentView = contentView
        window.isReleasedWhenClosed = false

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(attachedTo presentingWindow: NSWindow?) {
        guard let window else { return }

        if let presentingWindow, presentingWindow.isVisible {
            presentingWindow.beginSheet(window)
        } else {
            window.center()
            showWindow(nil)
            NSApp.activate()
        }
    }

    func updateStatus(_ status: String) {
        statusLabel.stringValue = status
    }

    func closeProgress() {
        guard let window else { return }

        if let sheetParent = window.sheetParent {
            sheetParent.endSheet(window)
        } else {
            close()
        }
    }
}
