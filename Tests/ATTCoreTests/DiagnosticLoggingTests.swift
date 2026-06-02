@testable import ATTCore
import Foundation
import Testing

@Suite("Diagnostic logging")
struct DiagnosticLoggingTests {
    @Test("events encode typed values and privacy metadata")
    func eventsEncodeTypedValuesAndPrivacyMetadata() throws {
        let event = DiagnosticLogEvent(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            level: .warning,
            category: "search",
            event: "search.displayed",
            fields: [
                "query": .query("SecretProject"),
                "path": .path("/Users/example/Documents/SecretProject/File.swift"),
                "count": .publicInt(42),
                "success": .publicBool(true)
            ]
        )

        let data = try DiagnosticLogger.encodeLine(event)
        let json = String(decoding: data, as: UTF8.self)

        #expect(json.contains("\"privacy\":\"query\""))
        #expect(json.contains("\"privacy\":\"path\""))
        #expect(json.contains("\"privacy\":\"public\""))
        #expect(json.contains("\"type\":\"integer\""))
        #expect(json.contains("\"type\":\"boolean\""))

        let decoded = try DiagnosticLogger.makeDecoder().decode(DiagnosticLogEvent.self, from: data)
        #expect(decoded == event)
    }

    @Test("logger prunes old and oversized local log files")
    func loggerPrunesOldAndOversizedLocalLogFiles() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsDiagnosticLogs-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldFile = directory.appendingPathComponent("diagnostic-log-20200101-000000-000-old.jsonl")
        let firstLargeFile = directory.appendingPathComponent("diagnostic-log-20260101-000000-000-a.jsonl")
        let secondLargeFile = directory.appendingPathComponent("diagnostic-log-20260101-000001-000-b.jsonl")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x31, count: 900).write(to: oldFile)
        try Data(repeating: 0x32, count: 900).write(to: firstLargeFile)
        try Data(repeating: 0x33, count: 900).write(to: secondLargeFile)
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-120)], ofItemAtPath: oldFile.path)
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-20)], ofItemAtPath: firstLargeFile.path)
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-10)], ofItemAtPath: secondLargeFile.path)

        let logger = DiagnosticLogger()
        logger.configure(
            directoryURL: directory,
            maxTotalBytes: 1_200,
            maxAge: 60,
            clock: { now },
            fileManager: fileManager
        )
        logger.log(category: "test", event: "test.prune", fields: ["value": .publicString("ok")])
        logger.flush()

        #expect(!fileManager.fileExists(atPath: oldFile.path))
        #expect(!fileManager.fileExists(atPath: firstLargeFile.path))
        #expect(fileManager.fileExists(atPath: secondLargeFile.path))
        let remainingBytes = logger.currentLogFileURLs().reduce(UInt64(0)) { total, url in
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            return total + ((attributes?[.size] as? NSNumber)?.uint64Value ?? 0)
        }
        #expect(remainingBytes <= 1_200)
    }

    @Test("logger rotates files when the active file crosses the size threshold")
    func loggerRotatesFilesWhenActiveFileCrossesSizeThreshold() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsDiagnosticRotation-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let logger = DiagnosticLogger()
        let now = Date()
        logger.configureForTesting(
            directoryURL: directory,
            maxTotalBytes: 20_000,
            maxAge: 60,
            maxFileBytes: 700,
            clock: { now },
            fileManager: fileManager
        )

        for index in 0..<8 {
            logger.log(
                category: "test",
                event: "test.rotation",
                fields: [
                    "index": .publicInt(index),
                    "payload": .privateString(String(repeating: "x", count: 240))
                ]
            )
        }
        logger.flush()

        let files = logger.currentLogFileURLs()
        #expect(files.count > 1)
        for file in files {
            let attributes = try fileManager.attributesOfItem(atPath: file.path)
            let size = try #require(attributes[.size] as? NSNumber).uint64Value
            #expect(size <= 1_400)
        }
    }

    @Test("standard minimum suppresses diagnostic level but keeps info warning and error")
    func standardMinimumSuppressesDiagnosticLevelButKeepsInfoWarningAndError() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsDiagnosticLevel-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let logger = DiagnosticLogger()
        logger.configure(
            directoryURL: directory,
            maxTotalBytes: 20_000,
            maxAge: 60,
            fileManager: fileManager
        )
        logger.setMinimumLevel(.info)
        logger.log(level: .diagnostic, category: "test", event: "test.diagnostic")
        logger.log(
            category: "test",
            event: "test.info",
            fields: ["count": .publicInt(1)],
            diagnosticFields: ["path": .path("/Users/alice/Secret.txt")]
        )
        logger.log(level: .warning, category: "test", event: "test.warning")
        logger.log(level: .error, category: "test", event: "test.error")

        let events = try loggedEvents(from: logger)
        #expect(!events.contains { $0.event == "test.diagnostic" })
        let infoEvent = try #require(events.first { $0.event == "test.info" })
        #expect(infoEvent.fields["count"] != nil)
        #expect(infoEvent.fields["path"] == nil)
        #expect(events.contains { $0.event == "test.warning" })
        #expect(events.contains { $0.event == "test.error" })
    }

    @Test("diagnostic minimum records diagnostic level events and diagnostic fields")
    func diagnosticMinimumRecordsDiagnosticLevelEventsAndDiagnosticFields() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsDiagnosticLevel-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let logger = DiagnosticLogger()
        logger.configure(
            directoryURL: directory,
            maxTotalBytes: 20_000,
            maxAge: 60,
            fileManager: fileManager
        )
        logger.setMinimumLevel(.diagnostic)
        logger.log(level: .diagnostic, category: "test", event: "test.diagnostic")
        logger.log(
            category: "test",
            event: "test.info",
            fields: [
                "path": .publicString("summary"),
                "count": .publicInt(1)
            ],
            diagnosticFields: [
                "path": .path("/Users/alice/Secret.txt")
            ]
        )

        let events = try loggedEvents(from: logger)
        #expect(events.contains { $0.event == "test.diagnostic" })
        let infoEvent = try #require(events.first { $0.event == "test.info" })
        #expect(infoEvent.fields["count"] != nil)
        #expect(infoEvent.fields["path"] == .path("/Users/alice/Secret.txt"))
    }

    @Test("standard export includes recent diagnostic context without duplicating standard events")
    func standardExportIncludesRecentDiagnosticContextWithoutDuplicatingStandardEvents() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsDiagnosticRecentContext-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let clock = MutableClock(Date(timeIntervalSince1970: 1_800_000_000))
        let logger = DiagnosticLogger()
        logger.configure(
            directoryURL: directory,
            maxTotalBytes: 50_000,
            maxAge: 60 * 60 * 24 * 365,
            clock: { clock.now },
            fileManager: fileManager
        )
        logger.setMinimumLevel(.info)
        logger.log(
            category: "test",
            event: "test.standard",
            fields: [
                "count": .publicInt(1)
            ],
            diagnosticFields: [
                "path": .path("/Users/alice/SecretStandard.txt")
            ]
        )
        logger.flush()
        clock.now = clock.now.addingTimeInterval(1)
        logger.log(
            level: .diagnostic,
            category: "test",
            event: "test.diagnostic",
            fields: [
                "path": .path("/Users/alice/SecretDiagnostic.txt")
            ]
        )

        let diskEvents = try loggedEvents(from: logger)
        let diskStandardEvent = try #require(diskEvents.first { $0.event == "test.standard" })
        #expect(diskStandardEvent.fields["count"] != nil)
        #expect(diskStandardEvent.fields["path"] == nil)
        #expect(!diskEvents.contains { $0.event == "test.diagnostic" })

        let exporter = DiagnosticLogExporter(logger: logger, clock: { clock.now }, fileManager: fileManager)
        let rawURL = directory.appendingPathComponent("raw-export.jsonl")
        try exporter.exportRaw(to: rawURL)
        let exportedEvents = try decodedEvents(in: rawURL)
        let exportedStandardEvents = exportedEvents.filter { $0.event == "test.standard" }
        #expect(exportedStandardEvents.count == 1)
        let exportedStandardEvent = try #require(exportedStandardEvents.first)
        #expect(exportedStandardEvent.fields["path"] == .path("/Users/alice/SecretStandard.txt"))
        #expect(exportedEvents.contains { $0.event == "test.diagnostic" })
        let metadataEvent = try #require(exportedEvents.first { $0.event == "diagnosticLog.exportMetadata" })
        #expect(metadataEvent.fields["recentDiagnosticContextCount"] == .publicInt(2))

        let anonymizedURL = directory.appendingPathComponent("anonymized-export.jsonl")
        try exporter.exportAnonymized(to: anonymizedURL)
        let anonymized = try String(contentsOf: anonymizedURL, encoding: .utf8)
        #expect(anonymized.contains("test.standard"))
        #expect(anonymized.contains("test.diagnostic"))
        #expect(!anonymized.contains("SecretStandard"))
        #expect(!anonymized.contains("SecretDiagnostic"))
    }

    @Test("standard recent diagnostic context is age bounded")
    func standardRecentDiagnosticContextIsAgeBounded() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsDiagnosticRecentContextAge-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let clock = MutableClock(Date(timeIntervalSince1970: 1_800_000_000))
        let logger = DiagnosticLogger()
        logger.configure(
            directoryURL: directory,
            maxTotalBytes: 50_000,
            maxAge: 60 * 60 * 24 * 365,
            clock: { clock.now },
            fileManager: fileManager
        )
        logger.setMinimumLevel(.info)
        logger.log(
            level: .diagnostic,
            category: "test",
            event: "test.oldDiagnostic",
            fields: ["path": .path("/Users/alice/OldSecret.txt")]
        )
        logger.flush()
        clock.now = clock.now.addingTimeInterval(181)
        logger.log(
            level: .diagnostic,
            category: "test",
            event: "test.recentDiagnostic",
            fields: ["path": .path("/Users/alice/RecentSecret.txt")]
        )

        let exporter = DiagnosticLogExporter(logger: logger, clock: { clock.now }, fileManager: fileManager)
        let rawURL = directory.appendingPathComponent("raw-export.jsonl")
        try exporter.exportRaw(to: rawURL)
        let exportedEvents = try decodedEvents(in: rawURL)
        #expect(!exportedEvents.contains { $0.event == "test.oldDiagnostic" })
        #expect(exportedEvents.contains { $0.event == "test.recentDiagnostic" })
        let metadataEvent = try #require(exportedEvents.first { $0.event == "diagnosticLog.exportMetadata" })
        #expect(metadataEvent.fields["recentDiagnosticContextCount"] == .publicInt(1))
    }

    @Test("anonymizer removes sensitive strings while preserving shape")
    func anonymizerRemovesSensitiveStringsWhilePreservingShape() throws {
        let path = "/Users/alice/Documents/SecretProject/File.swift"
        let query = "path:SecretProject ext:swift | owner:alice@example.com"
        let event = DiagnosticLogEvent(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            level: .info,
            category: "search",
            event: "search.displayed",
            fields: [
                "path": .path(path),
                "samePath": .path(path),
                "query": .query(query),
                "count": .publicInt(12)
            ]
        )

        let anonymized = DiagnosticLogAnonymizer(salt: "fixed-test-salt").anonymized(event)
        let data = try DiagnosticLogger.encodeLine(anonymized)
        let json = String(decoding: data, as: UTF8.self)

        #expect(!json.contains("alice"))
        #expect(!json.contains("SecretProject"))
        #expect(!json.contains("example.com"))
        #expect(json.contains("\"value\":12"))

        let anonymizedPath = try stringValue("path", in: anonymized)
        let anonymizedSamePath = try stringValue("samePath", in: anonymized)
        #expect(anonymizedPath.count == path.count)
        #expect(anonymizedPath.split(separator: "/", omittingEmptySubsequences: false).count == path.split(separator: "/", omittingEmptySubsequences: false).count)
        #expect(anonymizedPath == anonymizedSamePath)

        let anonymizedQuery = try stringValue("query", in: anonymized)
        #expect(anonymizedQuery.count == query.count)
        #expect(anonymizedQuery.contains(":"))
        #expect(anonymizedQuery.contains("|"))
    }

    @Test("exporter preserves ordering and handles malformed anonymized lines")
    func exporterPreservesOrderingAndHandlesMalformedAnonymizedLines() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsDiagnosticExport-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let logger = DiagnosticLogger()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        logger.configure(
            directoryURL: directory,
            maxTotalBytes: 50_000,
            maxAge: 60 * 60,
            clock: { now },
            fileManager: fileManager
        )

        let first = DiagnosticLogEvent(
            timestamp: now,
            level: .info,
            category: "test",
            event: "first.secret",
            fields: ["path": .path("/Users/alice/SecretOne.txt")]
        )
        let second = DiagnosticLogEvent(
            timestamp: now.addingTimeInterval(1),
            level: .info,
            category: "test",
            event: "second.secret",
            fields: ["path": .path("/Users/alice/SecretTwo.txt")]
        )

        let firstFile = directory.appendingPathComponent("diagnostic-log-20260101-000000-000-a.jsonl")
        let secondFile = directory.appendingPathComponent("diagnostic-log-20260101-000001-000-b.jsonl")
        try DiagnosticLogger.encodeLine(first).write(to: firstFile)
        try (String(decoding: DiagnosticLogger.encodeLine(second), as: UTF8.self) + "{not-json}\n").write(
            to: secondFile,
            atomically: true,
            encoding: .utf8
        )
        try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: firstFile.path)
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(1)], ofItemAtPath: secondFile.path)

        let exporter = DiagnosticLogExporter(logger: logger, clock: { now }, fileManager: fileManager)
        let rawURL = directory.appendingPathComponent("raw-export.jsonl")
        try exporter.exportRaw(to: rawURL)
        let raw = try String(contentsOf: rawURL, encoding: .utf8)
        #expect(raw.range(of: "first.secret")?.lowerBound ?? raw.endIndex < raw.range(of: "second.secret")?.lowerBound ?? raw.startIndex)
        #expect(raw.contains("{not-json}"))

        let anonymizedURL = directory.appendingPathComponent("anonymized-export.jsonl")
        try exporter.exportAnonymized(to: anonymizedURL)
        let anonymized = try String(contentsOf: anonymizedURL, encoding: .utf8)
        #expect(anonymized.contains("first.secret"))
        #expect(anonymized.contains("second.secret"))
        #expect(anonymized.contains("diagnosticLog.exportMalformedLines"))
        #expect(!anonymized.contains("SecretOne"))
        #expect(!anonymized.contains("SecretTwo"))
    }

    private func stringValue(_ key: String, in event: DiagnosticLogEvent) throws -> String {
        let field = try #require(event.fields[key])
        guard case .string(let value, _, _) = field.storage else {
            Issue.record("Expected string field for \(key)")
            return ""
        }
        return value
    }

    private func loggedEvents(from logger: DiagnosticLogger) throws -> [DiagnosticLogEvent] {
        logger.flush()
        let decoder = DiagnosticLogger.makeDecoder()
        return try logger.currentLogFileURLs().flatMap { fileURL -> [DiagnosticLogEvent] in
            try decodedEvents(in: fileURL, decoder: decoder)
        }
    }

    private func decodedEvents(
        in fileURL: URL,
        decoder: JSONDecoder = DiagnosticLogger.makeDecoder()
    ) throws -> [DiagnosticLogEvent] {
        let lines = try String(contentsOf: fileURL, encoding: .utf8)
            .split(separator: "\n")
        return lines.compactMap { line in
            try? decoder.decode(DiagnosticLogEvent.self, from: Data(line.utf8))
        }
    }
}

private final class MutableClock: @unchecked Sendable {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}
