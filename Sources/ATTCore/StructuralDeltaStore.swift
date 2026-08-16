import Foundation

/// Identifies the immutable snapshot that a structural delta is applied to.
///
/// The saved date is part of the identity because a rebuilt snapshot can have the
/// same schema and record count while containing different records.
struct StructuralDeltaBaseIdentity: Equatable, Sendable {
    let schemaVersion: Int
    let recordCount: Int
    let savedAt: Date

    func matches(_ other: StructuralDeltaBaseIdentity) -> Bool {
        schemaVersion == other.schemaVersion
            && recordCount == other.recordCount
            && abs(savedAt.timeIntervalSinceReferenceDate - other.savedAt.timeIntervalSinceReferenceDate) < 0.000_001
    }
}

/// FSEvent progress represented by a structural delta.
///
/// Root watermarks make the delta and cursor advance one durable unit. The
/// optional barrier records the reconciliation boundary covered by the delta.
struct StructuralDeltaFSEventMetadata: Equatable, Sendable {
    var rootWatermarks: [String: UInt64]
    var reconciliationBarrierEventID: UInt64?

    init(
        rootWatermarks: [String: UInt64] = [:],
        reconciliationBarrierEventID: UInt64? = nil
    ) {
        self.rootWatermarks = rootWatermarks
        self.reconciliationBarrierEventID = reconciliationBarrierEventID
    }

    mutating func merge(_ newer: StructuralDeltaFSEventMetadata) {
        for (root, eventID) in newer.rootWatermarks {
            rootWatermarks[root] = max(rootWatermarks[root] ?? 0, eventID)
        }
        if let newerBarrier = newer.reconciliationBarrierEventID {
            reconciliationBarrierEventID = max(reconciliationBarrierEventID ?? 0, newerBarrier)
        }
    }
}

enum StructuralDeltaChange: Equatable, Sendable {
    case upsert(FileRecord)
    case tombstone(path: String)
}

/// A compact latest-wins set of structural changes layered over an immutable snapshot.
struct StructuralDelta: Equatable, Sendable {
    let baseIdentity: StructuralDeltaBaseIdentity
    private(set) var savedAt: Date
    private(set) var fseventMetadata: StructuralDeltaFSEventMetadata?

    private var upsertsByPath: [String: FileRecord]
    private var tombstonedPaths: Set<String>

    init(
        baseIdentity: StructuralDeltaBaseIdentity,
        changes: [StructuralDeltaChange] = [],
        fseventMetadata: StructuralDeltaFSEventMetadata? = nil,
        savedAt: Date = Date()
    ) throws {
        try Self.validate(baseIdentity)
        guard savedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw StructuralDeltaStoreError.invalidDate
        }

        self.baseIdentity = baseIdentity
        self.savedAt = savedAt
        self.fseventMetadata = nil
        upsertsByPath = [:]
        tombstonedPaths = []
        try apply(changes, fseventMetadata: fseventMetadata, savedAt: savedAt)
    }

    var upserts: [FileRecord] {
        upsertsByPath.values.sorted { $0.path < $1.path }
    }

    var tombstones: [String] {
        tombstonedPaths.sorted()
    }

    var changeCount: Int {
        upsertsByPath.count + tombstonedPaths.count
    }

    var isEmpty: Bool {
        changeCount == 0
    }

    func upsert(for path: String) -> FileRecord? {
        upsertsByPath[path]
    }

    func containsTombstone(for path: String) -> Bool {
        tombstonedPaths.contains(path)
    }

    /// Applies changes in order. If a path occurs more than once, the final
    /// upsert or tombstone is the only state retained.
    mutating func apply(
        _ changes: [StructuralDeltaChange],
        fseventMetadata newerFSEventMetadata: StructuralDeltaFSEventMetadata? = nil,
        savedAt: Date = Date()
    ) throws {
        guard savedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw StructuralDeltaStoreError.invalidDate
        }

        for change in changes {
            switch change {
            case let .upsert(record):
                try Self.validate(record)
                tombstonedPaths.remove(record.path)
                upsertsByPath[record.path] = record
            case let .tombstone(path):
                try Self.validate(path: path)
                upsertsByPath.removeValue(forKey: path)
                tombstonedPaths.insert(path)
            }
        }

        if let newerFSEventMetadata {
            try Self.validate(newerFSEventMetadata)
            if fseventMetadata == nil {
                fseventMetadata = newerFSEventMetadata
            } else {
                fseventMetadata?.merge(newerFSEventMetadata)
            }
        }
        self.savedAt = savedAt
    }

    mutating func replaceFSEventMetadata(
        _ metadata: StructuralDeltaFSEventMetadata?,
        savedAt: Date = Date()
    ) throws {
        guard savedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw StructuralDeltaStoreError.invalidDate
        }
        if let metadata {
            try Self.validate(metadata)
        }
        fseventMetadata = metadata
        self.savedAt = savedAt
    }

    fileprivate func validateForPersistence() throws {
        try Self.validate(baseIdentity)
        guard savedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw StructuralDeltaStoreError.invalidDate
        }
        if let fseventMetadata {
            try Self.validate(fseventMetadata)
        }
        for record in upsertsByPath.values {
            try Self.validate(record)
        }
        for path in tombstonedPaths {
            try Self.validate(path: path)
        }
    }

    private static func validate(_ identity: StructuralDeltaBaseIdentity) throws {
        guard
            identity.schemaVersion >= 0,
            identity.schemaVersion <= Int(UInt32.max),
            identity.recordCount >= 0,
            identity.savedAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw StructuralDeltaStoreError.invalidBaseIdentity
        }
    }

    private static func validate(_ record: FileRecord) throws {
        try validate(path: record.path)
        guard
            record.modifiedTime.isFinite,
            record.createdTime?.isFinite ?? true
        else {
            throw StructuralDeltaStoreError.invalidDate
        }
    }

    private static func validate(_ metadata: StructuralDeltaFSEventMetadata) throws {
        for root in metadata.rootWatermarks.keys {
            try validate(path: root)
        }
    }

    private static func validate(path: String) throws {
        guard !path.isEmpty else {
            throw StructuralDeltaStoreError.invalidPath
        }
    }
}

enum StructuralDeltaLoadRejection: Error, Equatable, Sendable {
    case corrupt
    case unsupportedFormat(foundVersion: UInt32)
    case baseIdentityMismatch(found: StructuralDeltaBaseIdentity)
}

enum StructuralDeltaLoadResult: Equatable, Sendable {
    case missing
    case loaded(StructuralDelta)
    case rejected(StructuralDeltaLoadRejection)
}

enum StructuralDeltaStoreError: Error, Equatable {
    case invalidBaseIdentity
    case invalidDate
    case invalidPath
    case valueTooLarge
    case rejected(StructuralDeltaLoadRejection)
}

extension StructuralDeltaStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidBaseIdentity:
            return "The structural delta base identity is invalid."
        case .invalidDate:
            return "The structural delta contains an invalid date."
        case .invalidPath:
            return "The structural delta contains an empty path."
        case .valueTooLarge:
            return "The structural delta is too large to persist."
        case let .rejected(rejection):
            switch rejection {
            case .corrupt:
                return "The persisted structural delta is corrupt."
            case let .unsupportedFormat(version):
                return "Structural delta format version \(version) is not supported."
            case .baseIdentityMismatch:
                return "The persisted structural delta belongs to another base snapshot."
            }
        }
    }
}

/// Atomically persists a coalesced structural delta next to the immutable index package.
///
/// This type deliberately never reads, modifies, or removes the base snapshot. A
/// stale or corrupt delta is returned as a rejection and must be cleared
/// explicitly by the caller before new changes can be appended.
final class StructuralDeltaStore: @unchecked Sendable {
    static let fileName = "filename-index-structural-delta-v1.bin"
    private static let journalSuffix = ".journal"
    private static let maximumJournalByteCount = 16 * 1024 * 1024

    let url: URL

    private let fileManager: FileManager
    private let lock = NSLock()
    private var cachedDelta: StructuralDelta?

    private var journalURL: URL {
        URL(fileURLWithPath: url.path + Self.journalSuffix, isDirectory: false)
    }

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    convenience init(supportDirectory: URL, fileManager: FileManager = .default) {
        self.init(
            url: supportDirectory.appendingPathComponent(Self.fileName, isDirectory: false),
            fileManager: fileManager
        )
    }

    func load(expectedBaseIdentity: StructuralDeltaBaseIdentity) throws -> StructuralDeltaLoadResult {
        try lock.withLock {
            cachedDelta = nil
            return try loadUnlocked(expectedBaseIdentity: expectedBaseIdentity)
        }
    }

    func save(_ delta: StructuralDelta) throws {
        try lock.withLock {
            try saveUnlocked(delta)
        }
    }

    /// Loads the current delta, applies changes in order, and appends a durable
    /// independently checksummed journal frame.
    ///
    /// A rejected existing file is not overwritten implicitly. The owner must
    /// first decide that its base snapshot is authoritative and call `clear()`.
    @discardableResult
    func append(
        baseIdentity: StructuralDeltaBaseIdentity,
        changes: [StructuralDeltaChange],
        fseventMetadata: StructuralDeltaFSEventMetadata? = nil,
        savedAt: Date = Date()
    ) throws -> StructuralDelta {
        try lock.withLock {
            var delta: StructuralDelta
            if let cachedDelta, cachedDelta.baseIdentity.matches(baseIdentity) {
                delta = cachedDelta
            } else {
                switch try loadUnlocked(expectedBaseIdentity: baseIdentity) {
                case .missing:
                    delta = try StructuralDelta(baseIdentity: baseIdentity, savedAt: savedAt)
                    try saveUnlocked(delta)
                case let .loaded(loaded):
                    delta = loaded
                case let .rejected(rejection):
                    throw StructuralDeltaStoreError.rejected(rejection)
                }
            }

            let frame = try StructuralDelta(
                baseIdentity: baseIdentity,
                changes: changes,
                fseventMetadata: fseventMetadata,
                savedAt: savedAt
            )
            try appendJournalFrameUnlocked(frame)
            try delta.apply(
                changes,
                fseventMetadata: fseventMetadata,
                savedAt: savedAt
            )
            cachedDelta = delta

            let journalAttributes = try? fileManager.attributesOfItem(atPath: journalURL.path)
            let journalByteCount = (journalAttributes?[.size] as? NSNumber)?.intValue ?? 0
            if journalByteCount > Self.maximumJournalByteCount {
                try saveUnlocked(delta)
            }
            return delta
        }
    }

    func clear() throws {
        try lock.withLock {
            cachedDelta = nil
            for candidateURL in [url, journalURL] where fileManager.fileExists(atPath: candidateURL.path) {
                try fileManager.removeItem(at: candidateURL)
            }
        }
    }

    private func loadUnlocked(
        expectedBaseIdentity: StructuralDeltaBaseIdentity
    ) throws -> StructuralDeltaLoadResult {
        do {
            _ = try StructuralDelta(baseIdentity: expectedBaseIdentity, savedAt: expectedBaseIdentity.savedAt)
        } catch {
            throw StructuralDeltaStoreError.invalidBaseIdentity
        }

        guard fileManager.fileExists(atPath: url.path) else {
            return .missing
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        }

        switch StructuralDeltaBinaryCodec.decode(data) {
        case let .success(baseDelta):
            guard baseDelta.baseIdentity.matches(expectedBaseIdentity) else {
                return .rejected(.baseIdentityMismatch(found: baseDelta.baseIdentity))
            }
            do {
                let delta = try applyingJournalUnlocked(to: baseDelta)
                cachedDelta = delta
                return .loaded(delta)
            } catch {
                return .rejected(.corrupt)
            }
        case let .failure(rejection):
            return .rejected(rejection)
        }
    }

    private func saveUnlocked(_ delta: StructuralDelta) throws {
        let data = try StructuralDeltaBinaryCodec.encode(delta)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        if fileManager.fileExists(atPath: journalURL.path) {
            try fileManager.removeItem(at: journalURL)
        }
        cachedDelta = delta
    }

    private func appendJournalFrameUnlocked(_ frame: StructuralDelta) throws {
        let payload = try StructuralDeltaBinaryCodec.encode(frame)
        var framedData = Data()
        framedData.reserveCapacity(8 + payload.count)
        var payloadLength = UInt64(payload.count)
        for _ in 0..<8 {
            framedData.append(UInt8(payloadLength & 0xff))
            payloadLength >>= 8
        }
        framedData.append(payload)

        try fileManager.createDirectory(
            at: journalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: journalURL.path) {
            guard fileManager.createFile(atPath: journalURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: journalURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: framedData)
        try handle.synchronize()
    }

    private func applyingJournalUnlocked(to baseDelta: StructuralDelta) throws -> StructuralDelta {
        guard fileManager.fileExists(atPath: journalURL.path) else { return baseDelta }
        let data = try Data(contentsOf: journalURL, options: [.mappedIfSafe])
        var offset = 0
        var delta = baseDelta
        while offset < data.count {
            guard offset + 8 <= data.count else { throw CocoaError(.fileReadCorruptFile) }
            var rawLength: UInt64 = 0
            for byteIndex in 0..<8 {
                rawLength |= UInt64(data[offset + byteIndex]) << UInt64(byteIndex * 8)
            }
            offset += 8
            guard let length = Int(exactly: rawLength),
                  length >= 0,
                  length <= data.count - offset else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let payload = Data(data[offset..<(offset + length)])
            offset += length
            guard case let .success(frame) = StructuralDeltaBinaryCodec.decode(payload),
                  frame.baseIdentity.matches(delta.baseIdentity) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var changes = frame.tombstones.map { StructuralDeltaChange.tombstone(path: $0) }
            changes.append(contentsOf: frame.upserts.map { StructuralDeltaChange.upsert($0) })
            try delta.apply(
                changes,
                fseventMetadata: frame.fseventMetadata,
                savedAt: frame.savedAt
            )
        }
        return delta
    }
}

private enum StructuralDeltaBinaryCodec {
    private static let magic: UInt64 = 0x3141544c44545441 // ATTDLTA1 in little-endian byte order.
    private static let currentFormatVersion: UInt32 = 1
    private static let metadataPresentFlag: UInt32 = 1 << 0
    private static let barrierPresentFlag: UInt32 = 1 << 1
    private static let knownFlags = metadataPresentFlag | barrierPresentFlag
    private static let checksumByteCount = 8
    private static let minimumEncodedByteCount = 88
    private static let maximumEntryCount = 2_000_000
    private static let maximumStringByteCount = 16 * 1024 * 1024

    static func encode(_ delta: StructuralDelta) throws -> Data {
        try delta.validateForPersistence()

        let upserts = delta.upserts
        let tombstones = delta.tombstones
        let watermarks = delta.fseventMetadata?.rootWatermarks.sorted { $0.key < $1.key } ?? []
        guard
            upserts.count <= maximumEntryCount,
            tombstones.count <= maximumEntryCount,
            watermarks.count <= maximumEntryCount
        else {
            throw StructuralDeltaStoreError.valueTooLarge
        }

        var flags: UInt32 = 0
        if delta.fseventMetadata != nil {
            flags |= metadataPresentFlag
        }
        if delta.fseventMetadata?.reconciliationBarrierEventID != nil {
            flags |= barrierPresentFlag
        }

        let estimatedCapacity = delta.changeCount.multipliedReportingOverflow(by: 96)
        var writer = StructuralDeltaBinaryWriter(estimatedCapacity: estimatedCapacity.overflow
            ? minimumEncodedByteCount
            : min(minimumEncodedByteCount + estimatedCapacity.partialValue, 8 * 1024 * 1024))
        writer.append(magic)
        writer.append(currentFormatVersion)
        writer.append(flags)
        writer.append(UInt32(delta.baseIdentity.schemaVersion))
        writer.append(UInt32(0))
        writer.append(UInt64(delta.baseIdentity.recordCount))
        writer.append(delta.baseIdentity.savedAt.timeIntervalSinceReferenceDate.bitPattern)
        writer.append(delta.savedAt.timeIntervalSinceReferenceDate.bitPattern)
        writer.append(UInt64(upserts.count))
        writer.append(UInt64(tombstones.count))
        writer.append(UInt64(watermarks.count))
        writer.append(delta.fseventMetadata?.reconciliationBarrierEventID ?? 0)

        for record in upserts {
            try append(record, to: &writer)
        }
        for path in tombstones {
            try writer.append(path, maximumByteCount: maximumStringByteCount)
        }
        for (root, eventID) in watermarks {
            try writer.append(root, maximumByteCount: maximumStringByteCount)
            writer.append(eventID)
        }

        writer.append(checksum(writer.data))
        return writer.data
    }

    static func decode(_ data: Data) -> Result<StructuralDelta, StructuralDeltaLoadRejection> {
        guard data.count >= minimumEncodedByteCount else {
            return .failure(.corrupt)
        }

        do {
            var headerReader = StructuralDeltaBinaryReader(data: data, limit: data.count)
            guard try headerReader.readUInt64() == magic else {
                return .failure(.corrupt)
            }
            let version = try headerReader.readUInt32()
            guard version == currentFormatVersion else {
                return .failure(.unsupportedFormat(foundVersion: version))
            }

            let checksumOffset = data.count - checksumByteCount
            var checksumReader = StructuralDeltaBinaryReader(data: data, offset: checksumOffset, limit: data.count)
            let persistedChecksum = try checksumReader.readUInt64()
            guard persistedChecksum == checksum(data, upTo: checksumOffset) else {
                return .failure(.corrupt)
            }

            var reader = StructuralDeltaBinaryReader(data: data, limit: checksumOffset)
            guard try reader.readUInt64() == magic else {
                return .failure(.corrupt)
            }
            _ = try reader.readUInt32()
            let flags = try reader.readUInt32()
            let baseSchemaVersion = try reader.readUInt32()
            let reserved = try reader.readUInt32()
            let baseRecordCount = try reader.readUInt64()
            let baseSavedAt = TimeInterval(bitPattern: try reader.readUInt64())
            let savedAt = TimeInterval(bitPattern: try reader.readUInt64())
            let upsertCount = try reader.readCount(maximum: maximumEntryCount)
            let tombstoneCount = try reader.readCount(maximum: maximumEntryCount)
            let watermarkCount = try reader.readCount(maximum: maximumEntryCount)
            let barrierEventID = try reader.readUInt64()

            guard
                flags & ~knownFlags == 0,
                flags & barrierPresentFlag == 0 || flags & metadataPresentFlag != 0,
                flags & barrierPresentFlag != 0 || barrierEventID == 0,
                reserved == 0,
                baseRecordCount <= UInt64(Int.max),
                baseSavedAt.isFinite,
                savedAt.isFinite,
                minimumPayloadByteCount(
                    upserts: upsertCount,
                    tombstones: tombstoneCount,
                    watermarks: watermarkCount
                ).map({ $0 <= reader.remainingByteCount }) == true
            else {
                return .failure(.corrupt)
            }

            let baseIdentity = StructuralDeltaBaseIdentity(
                schemaVersion: Int(baseSchemaVersion),
                recordCount: Int(baseRecordCount),
                savedAt: Date(timeIntervalSinceReferenceDate: baseSavedAt)
            )
            var changes: [StructuralDeltaChange] = []
            changes.reserveCapacity(upsertCount + tombstoneCount)
            for _ in 0..<upsertCount {
                changes.append(.upsert(try readRecord(from: &reader)))
            }
            for _ in 0..<tombstoneCount {
                changes.append(.tombstone(path: try reader.readString(maximumByteCount: maximumStringByteCount)))
            }

            var rootWatermarks: [String: UInt64] = [:]
            rootWatermarks.reserveCapacity(watermarkCount)
            for _ in 0..<watermarkCount {
                let root = try reader.readString(maximumByteCount: maximumStringByteCount)
                guard !root.isEmpty else {
                    return .failure(.corrupt)
                }
                let eventID = try reader.readUInt64()
                rootWatermarks[root] = max(rootWatermarks[root] ?? 0, eventID)
            }
            guard reader.isAtEnd else {
                return .failure(.corrupt)
            }

            let hasMetadata = flags & metadataPresentFlag != 0
            guard hasMetadata || watermarkCount == 0 else {
                return .failure(.corrupt)
            }
            let metadata = hasMetadata
                ? StructuralDeltaFSEventMetadata(
                    rootWatermarks: rootWatermarks,
                    reconciliationBarrierEventID: flags & barrierPresentFlag == 0 ? nil : barrierEventID
                )
                : nil

            let delta = try StructuralDelta(
                baseIdentity: baseIdentity,
                changes: changes,
                fseventMetadata: metadata,
                savedAt: Date(timeIntervalSinceReferenceDate: savedAt)
            )
            return .success(delta)
        } catch {
            return .failure(.corrupt)
        }
    }

    private static func append(
        _ record: FileRecord,
        to writer: inout StructuralDeltaBinaryWriter
    ) throws {
        var flags: UInt32 = 0
        if record.isDirectory { flags |= 1 }
        if record.isHidden { flags |= 2 }
        if record.createdTime != nil { flags |= 4 }

        writer.append(record.id)
        writer.append(flags)
        writer.append(record.sizeBytes)
        writer.append(record.modifiedTime.bitPattern)
        writer.append((record.createdTime ?? 0).bitPattern)
        try writer.append(record.path, maximumByteCount: maximumStringByteCount)
        try writer.append(record.name, maximumByteCount: maximumStringByteCount)
        try writer.append(record.directoryPath, maximumByteCount: maximumStringByteCount)
        try writer.append(record.fileExtension, maximumByteCount: maximumStringByteCount)
        try writer.append(record.volumeName, maximumByteCount: maximumStringByteCount)
        try writer.append(record.normalizedName, maximumByteCount: maximumStringByteCount)
        try writer.append(record.normalizedPath, maximumByteCount: maximumStringByteCount)
    }

    private static func readRecord(
        from reader: inout StructuralDeltaBinaryReader
    ) throws -> FileRecord {
        let id = try reader.readUInt64()
        let flags = try reader.readUInt32()
        let sizeBytes = try reader.readUInt64()
        let modifiedTime = TimeInterval(bitPattern: try reader.readUInt64())
        let createdBits = try reader.readUInt64()
        let path = try reader.readString(maximumByteCount: maximumStringByteCount)
        let name = try reader.readString(maximumByteCount: maximumStringByteCount)
        let directoryPath = try reader.readString(maximumByteCount: maximumStringByteCount)
        let fileExtension = try reader.readString(maximumByteCount: maximumStringByteCount)
        let volumeName = try reader.readString(maximumByteCount: maximumStringByteCount)
        let normalizedName = try reader.readString(maximumByteCount: maximumStringByteCount)
        let normalizedPath = try reader.readString(maximumByteCount: maximumStringByteCount)

        guard flags & ~UInt32(7) == 0, !path.isEmpty, modifiedTime.isFinite else {
            throw StructuralDeltaStoreError.invalidPath
        }
        let createdTime = flags & 4 == 0 ? nil : TimeInterval(bitPattern: createdBits)
        guard createdTime?.isFinite ?? true else {
            throw StructuralDeltaStoreError.invalidDate
        }

        return FileRecord(
            id: id,
            path: path,
            name: name,
            directoryPath: directoryPath,
            fileExtension: fileExtension,
            sizeBytes: sizeBytes,
            modifiedTime: modifiedTime,
            createdTime: createdTime,
            isDirectory: flags & 1 != 0,
            isHidden: flags & 2 != 0,
            volumeName: volumeName,
            normalizedName: normalizedName,
            normalizedPath: normalizedPath
        )
    }

    private static func minimumPayloadByteCount(
        upserts: Int,
        tombstones: Int,
        watermarks: Int
    ) -> Int? {
        // A record has 36 fixed bytes and seven four-byte string lengths.
        let parts = [(upserts, 64), (tombstones, 4), (watermarks, 12)]
        var total = 0
        for (count, bytesPerEntry) in parts {
            let (bytes, multiplyOverflow) = count.multipliedReportingOverflow(by: bytesPerEntry)
            let (newTotal, addOverflow) = total.addingReportingOverflow(bytes)
            guard !multiplyOverflow, !addOverflow else { return nil }
            total = newTotal
        }
        return total
    }

    private static func checksum(_ data: Data, upTo limit: Int? = nil) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for index in 0..<(limit ?? data.count) {
            hash ^= UInt64(data[index])
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

private struct StructuralDeltaBinaryWriter {
    private(set) var data: Data

    init(estimatedCapacity: Int) {
        data = Data()
        data.reserveCapacity(max(estimatedCapacity, 0))
    }

    mutating func append(_ value: UInt32) {
        data.append(contentsOf: [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff)
        ])
    }

    mutating func append(_ value: UInt64) {
        data.append(contentsOf: [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 32) & 0xff),
            UInt8((value >> 40) & 0xff),
            UInt8((value >> 48) & 0xff),
            UInt8((value >> 56) & 0xff)
        ])
    }

    mutating func append(_ value: String, maximumByteCount: Int) throws {
        let byteCount = value.utf8.count
        guard byteCount <= maximumByteCount, byteCount <= Int(UInt32.max) else {
            throw StructuralDeltaStoreError.valueTooLarge
        }
        append(UInt32(byteCount))
        data.append(contentsOf: value.utf8)
    }
}

private struct StructuralDeltaBinaryReader {
    private let data: Data
    private let limit: Int
    private var offset: Int

    init(data: Data, offset: Int = 0, limit: Int) {
        self.data = data
        self.offset = offset
        self.limit = limit
    }

    var isAtEnd: Bool {
        offset == limit
    }

    var remainingByteCount: Int {
        limit - offset
    }

    mutating func readUInt32() throws -> UInt32 {
        guard offset >= 0, offset <= limit - 4 else {
            throw StructuralDeltaStoreError.valueTooLarge
        }
        let value = UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
        offset += 4
        return value
    }

    mutating func readUInt64() throws -> UInt64 {
        guard offset >= 0, offset <= limit - 8 else {
            throw StructuralDeltaStoreError.valueTooLarge
        }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(data[offset + index]) << UInt64(index * 8)
        }
        offset += 8
        return value
    }

    mutating func readCount(maximum: Int) throws -> Int {
        let value = try readUInt64()
        guard value <= UInt64(Int.max), value <= UInt64(maximum) else {
            throw StructuralDeltaStoreError.valueTooLarge
        }
        return Int(value)
    }

    mutating func readString(maximumByteCount: Int) throws -> String {
        let length = try readUInt32()
        guard
            length <= UInt32(maximumByteCount),
            UInt64(length) <= UInt64(remainingByteCount)
        else {
            throw StructuralDeltaStoreError.valueTooLarge
        }
        let end = offset + Int(length)
        guard let value = String(data: data[offset..<end], encoding: .utf8) else {
            throw StructuralDeltaStoreError.valueTooLarge
        }
        offset = end
        return value
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
