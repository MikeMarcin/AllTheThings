import Foundation

public enum DiagnosticLogLevel: String, Codable, CaseIterable, Sendable {
    case debug
    case diagnostic
    case info
    case warning
    case error

    var canDropUnderBackpressure: Bool {
        self == .debug || self == .diagnostic || self == .info
    }

    private var priority: Int {
        switch self {
        case .debug: 0
        case .diagnostic: 1
        case .info: 2
        case .warning: 3
        case .error: 4
        }
    }

    func isRecorded(withMinimumLevel minimumLevel: DiagnosticLogLevel) -> Bool {
        if self == .warning || self == .error {
            return true
        }
        return priority >= minimumLevel.priority
    }

    func includesDiagnosticFields() -> Bool {
        priority <= DiagnosticLogLevel.diagnostic.priority
    }
}

public enum DiagnosticLogFieldPrivacy: String, Codable, Sendable {
    case publicValue = "public"
    case path
    case pathArray
    case query
    case privateString
    case errorText

    var isSensitive: Bool {
        switch self {
        case .publicValue:
            return false
        case .path, .pathArray, .query, .privateString, .errorText:
            return true
        }
    }
}

public struct DiagnosticLogFieldValue: Codable, Equatable, Sendable {
    public enum Storage: Equatable, Sendable {
        case string(String, truncated: Bool, originalLength: Int?)
        case stringArray([String], totalCount: Int, truncated: Bool)
        case int(Int64)
        case uint(UInt64)
        case double(Double)
        case bool(Bool)
    }

    public let privacy: DiagnosticLogFieldPrivacy
    public let storage: Storage

    public init(privacy: DiagnosticLogFieldPrivacy, storage: Storage) {
        self.privacy = privacy
        self.storage = storage
    }

    public static func publicString(_ value: String) -> DiagnosticLogFieldValue {
        DiagnosticLogFieldValue(privacy: .publicValue, storage: .string(value, truncated: false, originalLength: nil))
    }

    public static func publicStringArray(_ values: [String]) -> DiagnosticLogFieldValue {
        DiagnosticLogFieldValue(privacy: .publicValue, storage: .stringArray(values, totalCount: values.count, truncated: false))
    }

    public static func publicInt(_ value: Int) -> DiagnosticLogFieldValue {
        DiagnosticLogFieldValue(privacy: .publicValue, storage: .int(Int64(value)))
    }

    public static func publicInt64(_ value: Int64) -> DiagnosticLogFieldValue {
        DiagnosticLogFieldValue(privacy: .publicValue, storage: .int(value))
    }

    public static func publicUInt64(_ value: UInt64) -> DiagnosticLogFieldValue {
        DiagnosticLogFieldValue(privacy: .publicValue, storage: .uint(value))
    }

    public static func publicDouble(_ value: Double) -> DiagnosticLogFieldValue {
        DiagnosticLogFieldValue(privacy: .publicValue, storage: .double(value))
    }

    public static func publicBool(_ value: Bool) -> DiagnosticLogFieldValue {
        DiagnosticLogFieldValue(privacy: .publicValue, storage: .bool(value))
    }

    public static func path(_ value: String) -> DiagnosticLogFieldValue {
        DiagnosticLogFieldValue(privacy: .path, storage: .string(value, truncated: false, originalLength: nil))
    }

    public static func pathArray(_ values: [String]) -> DiagnosticLogFieldValue {
        DiagnosticLogFieldValue(privacy: .pathArray, storage: .stringArray(values, totalCount: values.count, truncated: false))
    }

    public static func query(_ value: String) -> DiagnosticLogFieldValue {
        DiagnosticLogFieldValue(privacy: .query, storage: .string(value, truncated: false, originalLength: nil))
    }

    public static func privateString(_ value: String) -> DiagnosticLogFieldValue {
        DiagnosticLogFieldValue(privacy: .privateString, storage: .string(value, truncated: false, originalLength: nil))
    }

    public static func errorText(_ value: String) -> DiagnosticLogFieldValue {
        DiagnosticLogFieldValue(privacy: .errorText, storage: .string(value, truncated: false, originalLength: nil))
    }

    func capped(maxStringLength: Int, maxArrayValues: Int) -> DiagnosticLogFieldValue {
        let maxStringLength = max(maxStringLength, 0)
        let maxArrayValues = max(maxArrayValues, 0)

        switch storage {
        case .string(let value, _, _):
            guard value.count > maxStringLength else { return self }
            let capped = String(value.prefix(maxStringLength))
            return DiagnosticLogFieldValue(
                privacy: privacy,
                storage: .string(capped, truncated: true, originalLength: value.count)
            )
        case .stringArray(let values, let totalCount, _):
            var cappedValues = Array(values.prefix(maxArrayValues))
            var didTruncateStrings = false
            cappedValues = cappedValues.map { value in
                guard value.count > maxStringLength else { return value }
                didTruncateStrings = true
                return String(value.prefix(maxStringLength))
            }
            let truncated = values.count > maxArrayValues || didTruncateStrings
            return DiagnosticLogFieldValue(
                privacy: privacy,
                storage: .stringArray(cappedValues, totalCount: max(totalCount, values.count), truncated: truncated)
            )
        case .int, .uint, .double, .bool:
            return self
        }
    }

    private enum CodingKeys: String, CodingKey {
        case privacy
        case type
        case value
        case count
        case truncated
        case originalLength
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(privacy, forKey: .privacy)

        switch storage {
        case .string(let value, let truncated, let originalLength):
            try container.encode("string", forKey: .type)
            try container.encode(value, forKey: .value)
            if truncated {
                try container.encode(true, forKey: .truncated)
                try container.encode(originalLength, forKey: .originalLength)
            }
        case .stringArray(let values, let totalCount, let truncated):
            try container.encode("stringArray", forKey: .type)
            try container.encode(values, forKey: .value)
            try container.encode(totalCount, forKey: .count)
            if truncated {
                try container.encode(true, forKey: .truncated)
            }
        case .int(let value):
            try container.encode("integer", forKey: .type)
            try container.encode(value, forKey: .value)
        case .uint(let value):
            try container.encode("unsignedInteger", forKey: .type)
            try container.encode(value, forKey: .value)
        case .double(let value):
            try container.encode("double", forKey: .type)
            try container.encode(value, forKey: .value)
        case .bool(let value):
            try container.encode("boolean", forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        privacy = try container.decode(DiagnosticLogFieldPrivacy.self, forKey: .privacy)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "string":
            storage = .string(
                try container.decode(String.self, forKey: .value),
                truncated: try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false,
                originalLength: try container.decodeIfPresent(Int.self, forKey: .originalLength)
            )
        case "stringArray":
            let values = try container.decode([String].self, forKey: .value)
            storage = .stringArray(
                values,
                totalCount: try container.decodeIfPresent(Int.self, forKey: .count) ?? values.count,
                truncated: try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
            )
        case "integer":
            storage = .int(try container.decode(Int64.self, forKey: .value))
        case "unsignedInteger":
            storage = .uint(try container.decode(UInt64.self, forKey: .value))
        case "double":
            storage = .double(try container.decode(Double.self, forKey: .value))
        case "boolean":
            storage = .bool(try container.decode(Bool.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown diagnostic field type: \(type)"
            )
        }
    }
}

public struct DiagnosticLogEvent: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let timestamp: Date
    public let level: DiagnosticLogLevel
    public let category: String
    public let event: String
    public let fields: [String: DiagnosticLogFieldValue]

    public init(
        timestamp: Date,
        level: DiagnosticLogLevel,
        category: String,
        event: String,
        fields: [String: DiagnosticLogFieldValue] = [:],
        schemaVersion: Int = DiagnosticLogEvent.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.event = event
        self.fields = fields
    }

    func capped(maxStringLength: Int, maxArrayValues: Int) -> DiagnosticLogEvent {
        DiagnosticLogEvent(
            timestamp: timestamp,
            level: level,
            category: category,
            event: event,
            fields: fields.mapValues { $0.capped(maxStringLength: maxStringLength, maxArrayValues: maxArrayValues) },
            schemaVersion: schemaVersion
        )
    }
}

public final class DiagnosticLogger: @unchecked Sendable {
    public typealias Clock = @Sendable () -> Date

    public static let shared = DiagnosticLogger()

    private struct Configuration: @unchecked Sendable {
        let directoryURL: URL
        let maxTotalBytes: UInt64
        let maxAge: TimeInterval
        let clock: Clock
        let fileManager: FileManager
        let maxFileBytes: UInt64
    }

    private static let defaultMaxFileBytes: UInt64 = 5 * 1024 * 1024
    private static let maxPendingEvents = 4_096
    private static let flushEventCount = 16
    private static let flushInterval: TimeInterval = 1
    private static let maxStringLength = 4_096
    private static let reducedMaxStringLength = 1_024
    private static let maxArrayValues = 50
    private static let reducedMaxArrayValues = 10
    private static let maxLineBytes = 64 * 1024
    private static let logFilePrefix = "diagnostic-log-"
    private static let logFileExtension = "jsonl"

    private let queue = DispatchQueue(label: "att.diagnostic-log", qos: .utility)
    private let stateLock = NSLock()

    private var configuration: Configuration?
    private var pendingEventCount = 0
    private var droppedLowSeverityEvents: UInt64 = 0
    private var buffer: [DiagnosticLogEvent] = []
    private var currentLogFileURL: URL?
    private var currentLogFileBytes: UInt64 = 0
    private var flushTimer: DispatchSourceTimer?
    private var lastFlushDate = Date.distantPast
    private var minimumLevel: DiagnosticLogLevel = .info

    public init() {}

    public func configure(
        directoryURL: URL,
        maxTotalBytes: UInt64,
        maxAge: TimeInterval,
        clock: @escaping Clock = { Date() },
        fileManager: FileManager = .default
    ) {
        let configuration = Configuration(
            directoryURL: directoryURL,
            maxTotalBytes: maxTotalBytes,
            maxAge: maxAge,
            clock: clock,
            fileManager: fileManager,
            maxFileBytes: min(Self.defaultMaxFileBytes, max(maxTotalBytes, 1))
        )
        apply(configuration)
    }

    func configureForTesting(
        directoryURL: URL,
        maxTotalBytes: UInt64,
        maxAge: TimeInterval,
        maxFileBytes: UInt64,
        clock: @escaping Clock = { Date() },
        fileManager: FileManager = .default
    ) {
        apply(Configuration(
            directoryURL: directoryURL,
            maxTotalBytes: maxTotalBytes,
            maxAge: maxAge,
            clock: clock,
            fileManager: fileManager,
            maxFileBytes: max(maxFileBytes, 1)
        ))
    }

    private func apply(_ configuration: Configuration) {
        queue.sync {
            flushTimer?.cancel()
            flushTimer = nil
            buffer.removeAll(keepingCapacity: false)
            currentLogFileURL = nil
            currentLogFileBytes = 0
            lastFlushDate = configuration.clock()

            stateLock.withLock {
                self.configuration = configuration
                pendingEventCount = 0
                droppedLowSeverityEvents = 0
            }

            prepareLogDirectory(configuration)
            pruneLogs(configuration)
        }
    }

    public func log(
        level: DiagnosticLogLevel = .info,
        category: String,
        event: String,
        fields: [String: DiagnosticLogFieldValue] = [:],
        diagnosticFields: [String: DiagnosticLogFieldValue] = [:]
    ) {
        let configuredMinimumLevel = stateLock.withLock { minimumLevel }
        guard level.isRecorded(withMinimumLevel: configuredMinimumLevel) else {
            return
        }
        let fieldsToRecord: [String: DiagnosticLogFieldValue]
        if configuredMinimumLevel.includesDiagnosticFields() {
            fieldsToRecord = fields.merging(diagnosticFields) { _, diagnosticField in diagnosticField }
        } else {
            fieldsToRecord = fields
        }
        let shouldEnqueue = stateLock.withLock { () -> Bool in
            guard configuration != nil else { return false }
            if pendingEventCount >= Self.maxPendingEvents, level.canDropUnderBackpressure {
                droppedLowSeverityEvents &+= 1
                return false
            }
            pendingEventCount += 1
            return true
        }

        guard shouldEnqueue else { return }

        queue.async { [weak self] in
            guard let self else { return }
            stateLock.withLock {
                pendingEventCount = max(0, pendingEventCount - 1)
            }
            guard let configuration = stateLock.withLock({ self.configuration }) else { return }

            if let droppedSummary = takeDroppedSummary(configuration: configuration) {
                append(droppedSummary, configuration: configuration)
            }

            let logEvent = DiagnosticLogEvent(
                timestamp: configuration.clock(),
                level: level,
                category: category,
                event: event,
                fields: fieldsToRecord
            )
            append(logEvent, configuration: configuration)
        }
    }

    public func setMinimumLevel(_ minimumLevel: DiagnosticLogLevel) {
        stateLock.withLock {
            self.minimumLevel = minimumLevel
        }
    }

    public func currentMinimumLevel() -> DiagnosticLogLevel {
        stateLock.withLock { minimumLevel }
    }

    public func flush() {
        queue.sync {
            guard let configuration = stateLock.withLock({ self.configuration }) else { return }
            cancelFlushTimer()
            flushBuffer(configuration)
        }
    }

    public func clearLogs() throws {
        flush()
        try queue.sync {
            guard let configuration = stateLock.withLock({ self.configuration }) else { return }
            buffer.removeAll(keepingCapacity: false)
            currentLogFileURL = nil
            currentLogFileBytes = 0
            for url in logFileURLs(configuration: configuration) {
                try configuration.fileManager.removeItem(at: url)
            }
        }
    }

    func currentLogFileURLs() -> [URL] {
        flush()
        return queue.sync {
            guard let configuration = stateLock.withLock({ self.configuration }) else { return [] }
            return logFileURLs(configuration: configuration)
        }
    }

    func currentConfigurationSummary() -> (directoryURL: URL, maxTotalBytes: UInt64, maxAge: TimeInterval)? {
        stateLock.withLock {
            guard let configuration else { return nil }
            return (configuration.directoryURL, configuration.maxTotalBytes, configuration.maxAge)
        }
    }

    private func scheduleFlushTimerIfNeeded(_ configuration: Configuration) {
        guard flushTimer == nil, !buffer.isEmpty else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        let elapsedSinceLastFlush = configuration.clock().timeIntervalSince(lastFlushDate)
        let delay = max(Self.flushInterval - elapsedSinceLastFlush, 0)
        timer.schedule(deadline: .now() + delay, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            flushTimer = nil
            flushBuffer(configuration)
        }
        timer.resume()
        flushTimer = timer
    }

    private func cancelFlushTimer() {
        flushTimer?.cancel()
        flushTimer = nil
    }

    private func append(_ event: DiagnosticLogEvent, configuration: Configuration) {
        buffer.append(event)
        let shouldFlush = buffer.count >= Self.flushEventCount
            || configuration.clock().timeIntervalSince(lastFlushDate) >= Self.flushInterval
        if shouldFlush {
            cancelFlushTimer()
            flushBuffer(configuration)
        } else {
            scheduleFlushTimerIfNeeded(configuration)
        }
    }

    private func flushBuffer(_ configuration: Configuration) {
        guard !buffer.isEmpty else {
            pruneLogs(configuration)
            return
        }

        let events = buffer
        buffer.removeAll(keepingCapacity: true)

        for event in events {
            guard let line = encodedLine(for: event) else { continue }
            write(line, configuration: configuration)
        }

        lastFlushDate = configuration.clock()
        pruneLogs(configuration)
    }

    private func encodedLine(for event: DiagnosticLogEvent) -> Data? {
        let encoder = Self.makeEncoder()

        func encode(_ candidate: DiagnosticLogEvent) -> Data? {
            guard var data = try? encoder.encode(candidate) else { return nil }
            data.append(0x0A)
            return data
        }

        let capped = event.capped(
            maxStringLength: Self.maxStringLength,
            maxArrayValues: Self.maxArrayValues
        )
        if let data = encode(capped), data.count <= Self.maxLineBytes {
            return data
        }

        let reduced = event.capped(
            maxStringLength: Self.reducedMaxStringLength,
            maxArrayValues: Self.reducedMaxArrayValues
        )
        if let data = encode(reduced), data.count <= Self.maxLineBytes {
            return data
        }

        let fallback = DiagnosticLogEvent(
            timestamp: event.timestamp,
            level: event.level,
            category: "diagnosticLog",
            event: "diagnosticLog.eventTooLarge",
            fields: [
                "originalCategory": .publicString(event.category),
                "originalEvent": .publicString(event.event),
                "fieldCount": .publicInt(event.fields.count)
            ]
        )
        return encode(fallback)
    }

    private func write(_ line: Data, configuration: Configuration) {
        do {
            let fileURL = try writableLogFileURL(forAdditionalBytes: UInt64(line.count), configuration: configuration)
            let handle = try FileHandle(forWritingTo: fileURL)
            defer {
                try? handle.close()
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            currentLogFileBytes &+= UInt64(line.count)
        } catch {
            // Logging must never disturb the app's foreground work.
        }
    }

    private func writableLogFileURL(forAdditionalBytes bytes: UInt64, configuration: Configuration) throws -> URL {
        if
            let currentLogFileURL,
            currentLogFileBytes > 0,
            currentLogFileBytes + bytes <= configuration.maxFileBytes,
            configuration.fileManager.fileExists(atPath: currentLogFileURL.path)
        {
            return currentLogFileURL
        }

        if let currentLogFileURL, currentLogFileBytes == 0, configuration.fileManager.fileExists(atPath: currentLogFileURL.path) {
            return currentLogFileURL
        }

        let fileURL = configuration.directoryURL
            .appendingPathComponent("\(Self.logFilePrefix)\(Self.fileTimestamp(configuration.clock()))-\(UUID().uuidString).\(Self.logFileExtension)")

        if !configuration.fileManager.fileExists(atPath: fileURL.path) {
            configuration.fileManager.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
            )
        }
        try configuration.fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
        currentLogFileURL = fileURL
        currentLogFileBytes = fileSize(fileURL, fileManager: configuration.fileManager)
        return fileURL
    }

    private func prepareLogDirectory(_ configuration: Configuration) {
        do {
            try configuration.fileManager.createDirectory(
                at: configuration.directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
            try configuration.fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: configuration.directoryURL.path
            )
        } catch {
            // Keep logging best-effort and local.
        }
    }

    private func pruneLogs(_ configuration: Configuration) {
        let now = configuration.clock()
        var files = logFileRecords(configuration: configuration)

        for file in files where now.timeIntervalSince(file.modifiedAt) > configuration.maxAge {
            try? configuration.fileManager.removeItem(at: file.url)
        }

        files = logFileRecords(configuration: configuration)
        var totalBytes = files.reduce(UInt64(0)) { $0 &+ $1.bytes }
        for file in files where totalBytes > configuration.maxTotalBytes {
            try? configuration.fileManager.removeItem(at: file.url)
            totalBytes = totalBytes > file.bytes ? totalBytes - file.bytes : 0
            if file.url == currentLogFileURL {
                currentLogFileURL = nil
                currentLogFileBytes = 0
            }
        }
    }

    private func takeDroppedSummary(configuration: Configuration) -> DiagnosticLogEvent? {
        let dropped = stateLock.withLock { () -> UInt64 in
            let value = droppedLowSeverityEvents
            droppedLowSeverityEvents = 0
            return value
        }
        guard dropped > 0 else { return nil }
        return DiagnosticLogEvent(
            timestamp: configuration.clock(),
            level: .warning,
            category: "diagnosticLog",
            event: "diagnosticLog.droppedEvents",
            fields: [
                "droppedLowSeverityEvents": .publicUInt64(dropped)
            ]
        )
    }

    private struct LogFileRecord {
        let url: URL
        let bytes: UInt64
        let modifiedAt: Date
    }

    private func logFileURLs(configuration: Configuration) -> [URL] {
        logFileRecords(configuration: configuration).map(\.url)
    }

    private func logFileRecords(configuration: Configuration) -> [LogFileRecord] {
        let urls = (try? configuration.fileManager.contentsOfDirectory(
            at: configuration.directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.compactMap { url -> LogFileRecord? in
            guard url.lastPathComponent.hasPrefix(Self.logFilePrefix), url.pathExtension == Self.logFileExtension else {
                return nil
            }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return LogFileRecord(
                url: url,
                bytes: UInt64(values?.fileSize ?? Int(fileSize(url, fileManager: configuration.fileManager))),
                modifiedAt: values?.contentModificationDate ?? .distantPast
            )
        }
        .sorted {
            if $0.modifiedAt != $1.modifiedAt {
                return $0.modifiedAt < $1.modifiedAt
            }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }
    }

    private func fileSize(_ url: URL, fileManager: FileManager) -> UInt64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        if let size = attributes?[.size] as? NSNumber {
            return size.uint64Value
        }
        return 0
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encodeLine(_ event: DiagnosticLogEvent) throws -> Data {
        var data = try makeEncoder().encode(event)
        data.append(0x0A)
        return data
    }

    private static func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }
}

public final class DiagnosticLogAnonymizer: @unchecked Sendable {
    private let salt: String
    private var cache: [String: String] = [:]

    public init(salt: String = UUID().uuidString) {
        self.salt = salt
    }

    public func anonymized(_ event: DiagnosticLogEvent) -> DiagnosticLogEvent {
        DiagnosticLogEvent(
            timestamp: event.timestamp,
            level: event.level,
            category: event.category,
            event: event.event,
            fields: event.fields.mapValues(anonymizedField(_:)),
            schemaVersion: event.schemaVersion
        )
    }

    private func anonymizedField(_ field: DiagnosticLogFieldValue) -> DiagnosticLogFieldValue {
        guard field.privacy.isSensitive else { return field }

        switch field.storage {
        case .string(let value, let truncated, let originalLength):
            return DiagnosticLogFieldValue(
                privacy: field.privacy,
                storage: .string(
                    anonymizedString(value, privacy: field.privacy),
                    truncated: truncated,
                    originalLength: originalLength
                )
            )
        case .stringArray(let values, let totalCount, let truncated):
            return DiagnosticLogFieldValue(
                privacy: field.privacy,
                storage: .stringArray(
                    values.map { anonymizedString($0, privacy: field.privacy) },
                    totalCount: totalCount,
                    truncated: truncated
                )
            )
        case .int, .uint, .double, .bool:
            return field
        }
    }

    private func anonymizedString(_ value: String, privacy: DiagnosticLogFieldPrivacy) -> String {
        let cacheKey = "\(privacy.rawValue)\u{1F}\(value)"
        if let cached = cache[cacheKey] {
            return cached
        }

        let replacement = String(
            value.enumerated().map { offset, character in
                replacementCharacter(for: character, original: value, offset: offset, privacy: privacy)
            }
        )
        cache[cacheKey] = replacement
        return replacement
    }

    private func replacementCharacter(
        for character: Character,
        original: String,
        offset: Int,
        privacy: DiagnosticLogFieldPrivacy
    ) -> Character {
        if shouldPreserve(character, privacy: privacy) {
            return character
        }

        if character.isNumber {
            let digit = deterministicByte(original: original, offset: offset) % 10
            return Character(String(digit))
        }

        if character.isLetter {
            let alphabet = character.isUppercaseLetter
                ? Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
                : Array("abcdefghijklmnopqrstuvwxyz")
            let index = Int(deterministicByte(original: original, offset: offset) % UInt64(alphabet.count))
            return alphabet[index]
        }

        if character.isWhitespace {
            return character
        }

        let symbols = Array("!#$%&+;<=>@^~")
        let index = Int(deterministicByte(original: original, offset: offset) % UInt64(symbols.count))
        return symbols[index]
    }

    private func shouldPreserve(_ character: Character, privacy: DiagnosticLogFieldPrivacy) -> Bool {
        switch privacy {
        case .path, .pathArray:
            return character == "/" || character == "\\" || character == "." || character == "-"
                || character == "_" || character == " "
        case .query:
            return character.isWhitespace || ":!|-*?/.()[]{}\"'".contains(character)
        case .privateString, .errorText:
            return character.isWhitespace || "/\\.:,;()[]{}\"'".contains(character)
        case .publicValue:
            return true
        }
    }

    private func deterministicByte(original: String, offset: Int) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in salt.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        for byte in original.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        hash ^= UInt64(offset &+ 0x9E37)
        hash &*= 1_099_511_628_211
        return hash
    }
}

public final class DiagnosticLogExporter: @unchecked Sendable {
    public enum ExportKind: String, Sendable {
        case raw
        case anonymized
    }

    private let logger: DiagnosticLogger
    private let snapshotProvider: @Sendable () -> IndexInsightsSnapshot?
    private let clock: @Sendable () -> Date
    private let fileManager: FileManager

    public init(
        logger: DiagnosticLogger = .shared,
        snapshotProvider: @escaping @Sendable () -> IndexInsightsSnapshot? = { nil },
        clock: @escaping @Sendable () -> Date = { Date() },
        fileManager: FileManager = .default
    ) {
        self.logger = logger
        self.snapshotProvider = snapshotProvider
        self.clock = clock
        self.fileManager = fileManager
    }

    public func exportRaw(to destinationURL: URL) throws {
        try export(kind: .raw, to: destinationURL)
    }

    public func exportAnonymized(to destinationURL: URL) throws {
        try export(kind: .anonymized, to: destinationURL)
    }

    private func export(kind: ExportKind, to destinationURL: URL) throws {
        logger.flush()
        let files = logger.currentLogFileURLs()
        let configuration = logger.currentConfigurationSummary()
        let anonymizer = kind == .anonymized ? DiagnosticLogAnonymizer(salt: UUID().uuidString) : nil
        let output = try OutputWriter(url: destinationURL, fileManager: fileManager)

        try writeMetadata(
            kind: kind,
            files: files,
            configuration: configuration,
            output: output,
            anonymizer: anonymizer
        )

        var malformedLines = 0
        for file in files {
            switch kind {
            case .raw:
                try output.writeFileContents(file)
            case .anonymized:
                malformedLines += try writeAnonymizedLogFile(file, output: output, anonymizer: anonymizer)
            }
        }

        if malformedLines > 0 {
            let event = DiagnosticLogEvent(
                timestamp: clock(),
                level: .warning,
                category: "diagnosticLog",
                event: "diagnosticLog.exportMalformedLines",
                fields: [
                    "malformedLineCount": .publicInt(malformedLines)
                ]
            )
            try output.writeLine(DiagnosticLogger.encodeLine(event))
        }
    }

    private func writeMetadata(
        kind: ExportKind,
        files: [URL],
        configuration: (directoryURL: URL, maxTotalBytes: UInt64, maxAge: TimeInterval)?,
        output: OutputWriter,
        anonymizer: DiagnosticLogAnonymizer?
    ) throws {
        var fields: [String: DiagnosticLogFieldValue] = [
            "exportKind": .publicString(kind.rawValue),
            "logFileCount": .publicInt(files.count),
            "schemaVersion": .publicInt(DiagnosticLogEvent.currentSchemaVersion)
        ]
        if let configuration {
            fields["logDirectory"] = .path(configuration.directoryURL.path)
            fields["maxTotalBytes"] = .publicUInt64(configuration.maxTotalBytes)
            fields["maxAgeSeconds"] = .publicDouble(configuration.maxAge)
        }

        try writeEvent(
            DiagnosticLogEvent(
                timestamp: clock(),
                level: .info,
                category: "diagnosticLog",
                event: "diagnosticLog.exportMetadata",
                fields: fields
            ),
            output: output,
            anonymizer: anonymizer
        )

        if let snapshot = snapshotProvider() {
            try writeEvent(snapshotEvent(snapshot), output: output, anonymizer: anonymizer)
        }
    }

    private func writeEvent(
        _ event: DiagnosticLogEvent,
        output: OutputWriter,
        anonymizer: DiagnosticLogAnonymizer?
    ) throws {
        let event = anonymizer?.anonymized(event) ?? event
        try output.writeLine(DiagnosticLogger.encodeLine(event))
    }

    private func writeAnonymizedLogFile(
        _ file: URL,
        output: OutputWriter,
        anonymizer: DiagnosticLogAnonymizer?
    ) throws -> Int {
        guard let anonymizer else { return 0 }
        let data = try Data(contentsOf: file)
        let text = String(decoding: data, as: UTF8.self)
        var malformed = 0

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8) else {
                malformed += 1
                continue
            }

            do {
                let event = try DiagnosticLogger.makeDecoder().decode(DiagnosticLogEvent.self, from: lineData)
                try output.writeLine(DiagnosticLogger.encodeLine(anonymizer.anonymized(event)))
            } catch {
                malformed += 1
            }
        }

        return malformed
    }

    private func snapshotEvent(_ snapshot: IndexInsightsSnapshot) -> DiagnosticLogEvent {
        DiagnosticLogEvent(
            timestamp: clock(),
            level: .info,
            category: "diagnosticLog",
            event: "diagnosticLog.currentSnapshot",
            fields: [
                "generatedAt": .publicString(ISO8601DateFormatter().string(from: snapshot.generatedAt)),
                "indexPhase": .publicString(snapshot.health.phase.rawValue),
                "indexStatus": .publicString(snapshot.health.status),
                "schemaVersion": .publicInt(snapshot.health.schemaVersion),
                "snapshotRevision": .publicUInt64(snapshot.health.snapshotRevision),
                "resultCount": .publicInt(snapshot.health.resultCount),
                "visibleCount": .publicInt(snapshot.health.visibleCount ?? -1),
                "recordStoreKind": .publicString(snapshot.health.recordStoreKind),
                "activeIndexJobs": .publicInt(snapshot.health.activeIndexJobs),
                "rootCount": .publicInt(snapshot.roots.count),
                "rootPaths": .pathArray(snapshot.roots.map(\.path)),
                "attDataBytes": .publicUInt64(snapshot.storage.totalATTDataBytes),
                "indexPackageBytes": .publicUInt64(snapshot.storage.indexPackageBytes),
                "cacheBytes": .publicUInt64(snapshot.storage.cacheBytes),
                "searchesCompleted": .publicUInt64(snapshot.usage.allTimeSearches.completed),
                "fallbackScans": .publicUInt64(snapshot.usage.allTimeSearches.fallbackScans),
                "fullRebuilds": .publicUInt64(snapshot.usage.health.fullRebuilds),
                "incrementalRefreshBatches": .publicUInt64(snapshot.usage.health.incrementalRefreshBatches),
                "indexingFailures": .publicUInt64(snapshot.usage.health.indexingFailures),
                "persistFailures": .publicUInt64(snapshot.usage.health.persistFailures)
            ]
        )
    }

    private final class OutputWriter {
        private let handle: FileHandle

        init(url: URL, fileManager: FileManager) throws {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            fileManager.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
            )
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: url.path
            )
            handle = try FileHandle(forWritingTo: url)
        }

        deinit {
            try? handle.close()
        }

        func writeLine(_ data: Data) throws {
            try handle.write(contentsOf: data)
        }

        func writeFileContents(_ url: URL) throws {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else { return }
            try handle.write(contentsOf: data)
            if data.last != 0x0A {
                try handle.write(contentsOf: Data([0x0A]))
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension Character {
    var isUppercaseLetter: Bool {
        String(self).rangeOfCharacter(from: .uppercaseLetters) != nil
    }
}
