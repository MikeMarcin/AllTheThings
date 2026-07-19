@testable import ATTCore
import Foundation
import Testing

@Suite("Structural delta store", .serialized)
struct StructuralDeltaStoreTests {
    @Test("round trips changes, base identity, and FSEvent progress")
    func roundTripsDelta() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let base = makeBaseIdentity()
        let first = makeRecord(path: "/indexed/first.swift", size: 12, modifiedTime: 100, createdTime: 90)
        let metadata = StructuralDeltaFSEventMetadata(
            rootWatermarks: ["/indexed": 42, "/other": 81],
            reconciliationBarrierEventID: 77
        )
        let expected = try StructuralDelta(
            baseIdentity: base,
            changes: [
                .upsert(first),
                .tombstone(path: "/indexed/removed.swift")
            ],
            fseventMetadata: metadata,
            savedAt: Date(timeIntervalSinceReferenceDate: 20_000)
        )

        try fixture.store.save(expected)

        let result = try fixture.store.load(expectedBaseIdentity: base)
        guard case let .loaded(loaded) = result else {
            Issue.record("Expected a loaded structural delta, got \(result)")
            return
        }
        #expect(loaded == expected)
        #expect(loaded.upsert(for: first.path) == first)
        #expect(loaded.containsTombstone(for: "/indexed/removed.swift"))
    }

    @Test("append coalesces every path with the latest change winning")
    func appendCoalescesLatestChanges() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let base = makeBaseIdentity()
        let firstVersion = makeRecord(path: "/indexed/item.txt", size: 1, modifiedTime: 10)
        let secondVersion = makeRecord(path: "/indexed/item.txt", size: 2, modifiedTime: 20)
        let finalVersion = makeRecord(path: "/indexed/item.txt", size: 3, modifiedTime: 30)
        let restored = makeRecord(path: "/indexed/restored.txt", size: 4, modifiedTime: 40)

        _ = try fixture.store.append(
            baseIdentity: base,
            changes: [
                .upsert(firstVersion),
                .tombstone(path: restored.path)
            ],
            fseventMetadata: StructuralDeltaFSEventMetadata(
                rootWatermarks: ["/indexed": 10],
                reconciliationBarrierEventID: 12
            ),
            savedAt: Date(timeIntervalSinceReferenceDate: 21_000)
        )
        _ = try fixture.store.append(
            baseIdentity: base,
            changes: [
                .upsert(secondVersion),
                .tombstone(path: secondVersion.path),
                .upsert(finalVersion),
                .upsert(restored)
            ],
            fseventMetadata: StructuralDeltaFSEventMetadata(
                rootWatermarks: ["/indexed": 9, "/other": 30],
                reconciliationBarrierEventID: 11
            ),
            savedAt: Date(timeIntervalSinceReferenceDate: 22_000)
        )

        let loaded = try requireLoaded(fixture.store.load(expectedBaseIdentity: base))
        #expect(loaded.changeCount == 2)
        #expect(loaded.upsert(for: finalVersion.path) == finalVersion)
        #expect(loaded.upsert(for: restored.path) == restored)
        #expect(!loaded.containsTombstone(for: finalVersion.path))
        #expect(!loaded.containsTombstone(for: restored.path))
        #expect(loaded.fseventMetadata?.rootWatermarks == ["/indexed": 10, "/other": 30])
        #expect(loaded.fseventMetadata?.reconciliationBarrierEventID == 12)
        #expect(loaded.savedAt == Date(timeIntervalSinceReferenceDate: 22_000))
    }

    @Test("missing files and repeated clears are harmless")
    func missingAndClearAreHarmless() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let base = makeBaseIdentity()
        #expect(try fixture.store.load(expectedBaseIdentity: base) == .missing)

        _ = try fixture.store.append(
            baseIdentity: base,
            changes: [.tombstone(path: "/indexed/deleted")]
        )
        #expect(FileManager.default.fileExists(atPath: fixture.store.url.path))

        try fixture.store.clear()
        try fixture.store.clear()
        #expect(try fixture.store.load(expectedBaseIdentity: base) == .missing)
    }

    @Test("a mismatched base is rejected without overwriting either file")
    func rejectsMismatchedBaseWithoutDamage() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let baseURL = fixture.directory.appendingPathComponent("base-snapshot.bin")
        let baseBytes = Data("immutable base".utf8)
        try baseBytes.write(to: baseURL)

        let storedBase = makeBaseIdentity()
        let delta = try StructuralDelta(
            baseIdentity: storedBase,
            changes: [.upsert(makeRecord(path: "/indexed/item"))]
        )
        try fixture.store.save(delta)
        let deltaBytes = try Data(contentsOf: fixture.store.url)

        let differentBase = StructuralDeltaBaseIdentity(
            schemaVersion: storedBase.schemaVersion,
            recordCount: storedBase.recordCount + 1,
            savedAt: storedBase.savedAt
        )
        #expect(
            try fixture.store.load(expectedBaseIdentity: differentBase)
                == .rejected(.baseIdentityMismatch(found: storedBase))
        )

        do {
            _ = try fixture.store.append(
                baseIdentity: differentBase,
                changes: [.tombstone(path: "/indexed/item")]
            )
            Issue.record("Appending to a mismatched delta should fail")
        } catch let error as StructuralDeltaStoreError {
            #expect(error == .rejected(.baseIdentityMismatch(found: storedBase)))
        }

        #expect(try Data(contentsOf: fixture.store.url) == deltaBytes)
        #expect(try Data(contentsOf: baseURL) == baseBytes)
    }

    @Test("corrupt and truncated deltas are rejected without touching the base")
    func rejectsCorruptDeltaWithoutDamage() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let baseURL = fixture.directory.appendingPathComponent("base-snapshot.bin")
        let baseBytes = Data("immutable base".utf8)
        try baseBytes.write(to: baseURL)

        let base = makeBaseIdentity()
        try fixture.store.save(StructuralDelta(
            baseIdentity: base,
            changes: [.upsert(makeRecord(path: "/indexed/item-with-payload"))]
        ))
        var corruptBytes = try Data(contentsOf: fixture.store.url)
        corruptBytes[corruptBytes.count / 2] ^= 0xff
        try corruptBytes.write(to: fixture.store.url)

        #expect(try fixture.store.load(expectedBaseIdentity: base) == .rejected(.corrupt))
        #expect(try Data(contentsOf: fixture.store.url) == corruptBytes)
        #expect(try Data(contentsOf: baseURL) == baseBytes)

        try Data(corruptBytes.prefix(24)).write(to: fixture.store.url)
        #expect(try fixture.store.load(expectedBaseIdentity: base) == .rejected(.corrupt))
        #expect(try Data(contentsOf: baseURL) == baseBytes)
    }

    @Test("an unsupported format is distinguished from corrupt payload data")
    func rejectsUnsupportedFormat() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let base = makeBaseIdentity()
        try fixture.store.save(StructuralDelta(baseIdentity: base))
        var bytes = try Data(contentsOf: fixture.store.url)
        bytes[8] = 2
        bytes[9] = 0
        bytes[10] = 0
        bytes[11] = 0
        try bytes.write(to: fixture.store.url)

        #expect(
            try fixture.store.load(expectedBaseIdentity: base)
                == .rejected(.unsupportedFormat(foundVersion: 2))
        )
    }

    @Test("optional empty FSEvent metadata remains distinct from no metadata")
    func preservesOptionalFSEventMetadata() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let base = makeBaseIdentity()
        var delta = try StructuralDelta(baseIdentity: base)
        try fixture.store.save(delta)
        #expect(try requireLoaded(fixture.store.load(expectedBaseIdentity: base)).fseventMetadata == nil)

        try delta.replaceFSEventMetadata(StructuralDeltaFSEventMetadata())
        try fixture.store.save(delta)
        #expect(
            try requireLoaded(fixture.store.load(expectedBaseIdentity: base)).fseventMetadata
                == StructuralDeltaFSEventMetadata()
        )
    }

    private func makeBaseIdentity() -> StructuralDeltaBaseIdentity {
        StructuralDeltaBaseIdentity(
            schemaVersion: 7,
            recordCount: 866_220,
            savedAt: Date(timeIntervalSinceReferenceDate: 19_000.125)
        )
    }

    private func makeRecord(
        path: String,
        size: UInt64 = 0,
        modifiedTime: TimeInterval = 100,
        createdTime: TimeInterval? = nil
    ) -> FileRecord {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        return FileRecord(
            id: FileRecord.stableID(for: path),
            path: path,
            name: name,
            directoryPath: url.deletingLastPathComponent().path,
            fileExtension: url.pathExtension,
            sizeBytes: size,
            modifiedTime: modifiedTime,
            createdTime: createdTime,
            isDirectory: false,
            isHidden: false,
            volumeName: "Test",
            normalizedName: name.lowercased(),
            normalizedPath: path.lowercased()
        )
    }

    private func makeFixture() throws -> StoreFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StructuralDeltaStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return StoreFixture(
            directory: directory,
            store: StructuralDeltaStore(supportDirectory: directory)
        )
    }

    private func requireLoaded(_ result: StructuralDeltaLoadResult) throws -> StructuralDelta {
        guard case let .loaded(delta) = result else {
            Issue.record("Expected a loaded structural delta, got \(result)")
            throw CocoaError(.fileReadCorruptFile)
        }
        return delta
    }
}

private struct StoreFixture {
    let directory: URL
    let store: StructuralDeltaStore

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
