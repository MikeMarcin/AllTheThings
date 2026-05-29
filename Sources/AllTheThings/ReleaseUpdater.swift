import AppKit
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

    private nonisolated static let latestReleaseURL = URL(string: "https://api.github.com/repos/MikeMarcin/AllTheThings/releases/latest")!
    private nonisolated static let releasesURL = URL(string: "https://github.com/MikeMarcin/AllTheThings/releases")!
    private nonisolated static let checkInterval: TimeInterval = 24 * 60 * 60
    private nonisolated static let appName = "AllTheThings"

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

        do {
            progressWindowController?.updateStatus("Downloading \(asset.name)...")
            let downloaded = try await Self.download(asset: asset)
            workDirectory = downloaded.workDirectory

            try Task.checkCancellation()
            progressWindowController?.updateStatus("Preparing update...")
            let prepared = try await Task.detached(priority: .userInitiated) {
                try Self.prepareDownloadedApp(downloaded: downloaded, asset: asset)
            }.value

            try Task.checkCancellation()
            progressWindowController?.updateStatus("Validating update...")
            let currentAppURL = Bundle.main.bundleURL
            let currentVersion = currentBundleVersion()
            guard let currentBundleIdentifier = Bundle.main.bundleIdentifier else {
                throw UpdateError.missingBundleIdentifier(currentAppURL)
            }

            try await Task.detached(priority: .userInitiated) {
                try Self.validatePreparedApp(
                    at: prepared.appURL,
                    expectedBundleIdentifier: currentBundleIdentifier,
                    currentAppURL: currentAppURL,
                    currentVersion: currentVersion
                )
            }.value

            try Self.preflightInstallPermissions(currentAppURL: currentAppURL)

            try Task.checkCancellation()
            progressWindowController?.updateStatus("Installing and restarting...")
            let helperURL = try Self.writeInstallHelper(
                preparedAppURL: prepared.appURL,
                currentAppURL: currentAppURL,
                workDirectory: prepared.workDirectory
            )
            try Self.launchInstallHelper(at: helperURL)

            shouldCleanUp = false
            defaults.removeObject(forKey: DefaultsKey.skippedReleaseTag)
            progressWindowController?.closeProgress()
            progressWindowController = nil
            NSApp.terminate(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                Darwin.exit(EXIT_SUCCESS)
            }
        } catch {
            if shouldCleanUp, let workDirectory {
                try? FileManager.default.removeItem(at: workDirectory)
            }
            throw error
        }
    }

    private nonisolated static func download(asset: GitHubAsset) async throws -> DownloadedAsset {
        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("\(appName)-Update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        var request = URLRequest(url: asset.browserDownloadURL)
        request.setValue("AllTheThings update installer", forHTTPHeaderField: "User-Agent")

        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw UpdateError.downloadFailed(httpResponse.statusCode)
        }

        let destination = workDirectory.appendingPathComponent(sanitizedFileName(asset.name), isDirectory: false)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: temporaryURL, to: destination)

        return DownloadedAsset(archiveURL: destination, workDirectory: workDirectory)
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

        _ = try runCommand("/usr/bin/hdiutil", arguments: [
            "attach",
            downloaded.archiveURL.path,
            "-nobrowse",
            "-readonly",
            "-mountpoint",
            mountPoint.path
        ])
        defer {
            _ = try? runCommand("/usr/bin/hdiutil", arguments: [
                "detach",
                mountPoint.path,
                "-quiet"
            ])
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
    ) throws {
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
    }

    private nonisolated static func validateCodeSignature(candidateURL: URL, currentAppURL: URL) throws {
        let candidateCode = try staticCode(for: candidateURL)
        let currentCode = try staticCode(for: currentAppURL)
        let strictFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)

        var status = SecStaticCodeCheckValidity(candidateCode, strictFlags, nil)
        guard status == errSecSuccess else {
            throw UpdateError.codeSignatureInvalid(candidateURL, status)
        }

        var requirement: SecRequirement?
        status = SecCodeCopyDesignatedRequirement(currentCode, SecCSFlags(), &requirement)
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
        workDirectory: URL
    ) throws -> URL {
        let helperURL = workDirectory.appendingPathComponent("install-update.zsh", isDirectory: false)
        let processIdentifier = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/zsh
        set -euo pipefail

        app_path=\(shellQuoted(currentAppURL.path))
        new_app=\(shellQuoted(preparedAppURL.path))
        work_dir=\(shellQuoted(workDirectory.path))
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

            if ! /usr/bin/ditto "${new_app}" "${app_path}"; then
                /bin/rm -rf "${app_path}"
                if [[ -d "${backup_path}" ]]; then
                    /bin/mv "${backup_path}" "${app_path}"
                    /usr/bin/open "${app_path}" || true
                fi
                exit 1
            fi

            /usr/bin/xattr -dr com.apple.quarantine "${app_path}" 2>/dev/null || true
            /bin/rm -rf "${backup_path}"
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

    @discardableResult
    private nonisolated static func runCommand(_ executablePath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combinedOutput = [output, error].joined(separator: "\n")
        guard process.terminationStatus == 0 else {
            throw UpdateError.commandFailed(
                command: URL(fileURLWithPath: executablePath).lastPathComponent,
                status: process.terminationStatus,
                output: combinedOutput
            )
        }

        return combinedOutput
    }

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
