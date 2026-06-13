import Foundation

enum RecordStoreKind: String, Sendable {
    case empty
    case heapPaged
    case mapped
    case overlay
}

enum RootAttributionError: LocalizedError {
    case tooManyRoots(Int)

    var errorDescription: String? {
        switch self {
        case .tooManyRoots(let count):
            return "The index supports at most \(RootAttributionTable.maximumRootCount.formatted()) roots, but \(count.formatted()) were configured."
        }
    }
}

struct RootAttributionInput: Sendable {
    let path: String
    let isResultRow: Bool
    let isDirectory: Bool
    let isHidden: Bool
    let sizeBytes: UInt64
}

struct RootAttributionBuildResult: Sendable {
    let table: RootAttributionTable
    let rootIDs: [UInt16]
}

struct RootAttributionSummary: Codable, Equatable, Sendable {
    let id: UInt16
    let path: String
    var trackedFileCount: Int
    var directoryCount: Int
    var hiddenCount: Int
    var indexedContentBytes: UInt64
    var pathByteWeight: UInt64

    init(
        id: UInt16,
        path: String,
        trackedFileCount: Int = 0,
        directoryCount: Int = 0,
        hiddenCount: Int = 0,
        indexedContentBytes: UInt64 = 0,
        pathByteWeight: UInt64 = 0
    ) {
        self.id = id
        self.path = path
        self.trackedFileCount = trackedFileCount
        self.directoryCount = directoryCount
        self.hiddenCount = hiddenCount
        self.indexedContentBytes = indexedContentBytes
        self.pathByteWeight = pathByteWeight
    }
}

struct RootAttributionTable: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumRootCount = Int(UInt16.max)
    static let unassignedRootID = UInt16.max

    let schemaVersion: Int
    var roots: [RootAttributionSummary]

    init(schemaVersion: Int = Self.currentSchemaVersion, roots: [RootAttributionSummary]) {
        self.schemaVersion = schemaVersion
        self.roots = roots
    }

    var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && roots.count <= Self.maximumRootCount
            && roots.enumerated().allSatisfy { index, summary in
                summary.id == UInt16(index) && !summary.path.isEmpty
            }
    }

    func rootPath(for id: UInt16) -> String? {
        guard id != Self.unassignedRootID else { return nil }
        let index = Int(id)
        guard index >= 0, index < roots.count else { return nil }
        return roots[index].path
    }

    func rootID(for path: String) -> UInt16? {
        let normalizedPath = Self.normalizedPath(path)
        return Self.ownerID(for: normalizedPath, matchers: rootsBySpecificity())
    }

    mutating func add(_ input: RootAttributionInput, to rootID: UInt16) {
        adjust(input, rootID: rootID, delta: 1)
    }

    mutating func subtract(_ input: RootAttributionInput, from rootID: UInt16) {
        adjust(input, rootID: rootID, delta: -1)
    }

    private mutating func adjust(_ input: RootAttributionInput, rootID: UInt16, delta: Int) {
        guard rootID != Self.unassignedRootID, input.isResultRow else { return }
        let index = Int(rootID)
        guard index >= 0, index < roots.count else { return }

        if input.isDirectory {
            roots[index].directoryCount = max(0, roots[index].directoryCount + delta)
        } else {
            roots[index].trackedFileCount = max(0, roots[index].trackedFileCount + delta)
            if delta >= 0 {
                roots[index].indexedContentBytes &+= input.sizeBytes
            } else {
                roots[index].indexedContentBytes = roots[index].indexedContentBytes > input.sizeBytes
                    ? roots[index].indexedContentBytes - input.sizeBytes
                    : 0
            }
        }

        if input.isHidden {
            roots[index].hiddenCount = max(0, roots[index].hiddenCount + delta)
        }

        let pathBytes = UInt64(input.path.utf8.count)
        if delta >= 0 {
            roots[index].pathByteWeight &+= pathBytes
        } else {
            roots[index].pathByteWeight = roots[index].pathByteWeight > pathBytes
                ? roots[index].pathByteWeight - pathBytes
                : 0
        }
    }

    static func build(
        roots rawRoots: [String],
        rowCount: Int,
        inputAt: (Int) -> RootAttributionInput
    ) throws -> RootAttributionBuildResult {
        let normalizedRoots = normalizedRootPaths(rawRoots)
        guard normalizedRoots.count <= maximumRootCount else {
            throw RootAttributionError.tooManyRoots(normalizedRoots.count)
        }

        var summaries = normalizedRoots.enumerated().map { index, path in
            RootAttributionSummary(id: UInt16(index), path: path)
        }
        let matchers = summaries.sorted {
            if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
            return $0.id < $1.id
        }

        var rowRootIDs: [UInt16] = []
        rowRootIDs.reserveCapacity(rowCount)

        for rowID in 0..<rowCount {
            let input = inputAt(rowID)
            let ownerID = ownerID(for: input.path, matchers: matchers) ?? unassignedRootID
            rowRootIDs.append(ownerID)
            guard ownerID != unassignedRootID, input.isResultRow else { continue }
            summaries[Int(ownerID)].apply(input)
        }

        return RootAttributionBuildResult(
            table: RootAttributionTable(roots: summaries),
            rootIDs: rowRootIDs
        )
    }

    static func normalizedRootPaths(_ roots: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(roots.count)

        for root in roots {
            let path = normalizedPath(root)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            result.append(path)
        }

        return result
    }

    private func rootsBySpecificity() -> [RootAttributionSummary] {
        roots.sorted {
            if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
            return $0.id < $1.id
        }
    }

    private static func ownerID(for path: String, matchers: [RootAttributionSummary]) -> UInt16? {
        matchers.first { summary in
            if summary.path == "/" {
                return path == "/" || path.hasPrefix("/")
            }
            return path == summary.path || path.hasPrefix(summary.path + "/")
        }?.id
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }
}

private extension RootAttributionSummary {
    mutating func apply(_ input: RootAttributionInput) {
        if input.isDirectory {
            directoryCount += 1
        } else {
            trackedFileCount += 1
            indexedContentBytes &+= input.sizeBytes
        }
        if input.isHidden {
            hiddenCount += 1
        }
        pathByteWeight &+= UInt64(input.path.utf8.count)
    }
}

protocol RecordStore: AnyObject, Sendable {
    var count: Int { get }
    var kind: RecordStoreKind { get }
    var mappedByteSize: Int { get }
    var heapPageCount: Int { get }
    var overlayCount: Int { get }
    var hasColumnarSidecars: Bool { get }
    var storedVisibleCount: Int? { get }
    var storedResultCount: Int? { get }
    var storedRootAttribution: RootAttributionTable? { get }
    var schemaVersion: Int { get }

    func record(at index: Int) -> FileRecord
    func view(at index: Int) -> RecordSearchView
    func rowID(forPath path: String) -> Int?
    func allRecords() -> [FileRecord]
    func recordID(at index: Int) -> UInt64
    func path(at index: Int) -> String
    func name(at index: Int) -> String
    func directoryPath(at index: Int) -> String
    func fileExtension(at index: Int) -> String
    func sizeBytes(at index: Int) -> UInt64
    func modifiedTime(at index: Int) -> TimeInterval
    func createdTime(at index: Int) -> TimeInterval?
    func isDirectory(at index: Int) -> Bool
    func isHidden(at index: Int) -> Bool
    func volumeName(at index: Int) -> String
    func normalizedName(at index: Int) -> String
    func normalizedPath(at index: Int) -> String
    func parentRowID(at index: Int) -> Int?
    func subtreeEnd(at index: Int) -> Int
    func depth(at index: Int) -> Int
    func rootID(at index: Int) -> UInt16?
    func rootPath(at index: Int) -> String?
    func isResultRow(at index: Int) -> Bool
    func isVirtual(at index: Int) -> Bool
    func isVisible(at index: Int) -> Bool
    func normalizedPath(at index: Int, contains token: String, cache: inout [Int: Bool]) -> Bool
    func normalizedName(at index: Int, contains token: String) -> Bool
    func normalizedName(at index: Int, contains tokenBytes: [UInt8]) -> Bool
    func isHiddenInPath(at index: Int, cache: inout [Int: Bool]) -> Bool
}

struct RecordSearchView: Sendable {
    fileprivate let store: RecordStore
    let rowID: Int

    var id: UInt64 { store.recordID(at: rowID) }
    var path: String { store.path(at: rowID) }
    var name: String { store.name(at: rowID) }
    var directoryPath: String { store.directoryPath(at: rowID) }
    var fileExtension: String { store.fileExtension(at: rowID) }
    var sizeBytes: UInt64 { store.sizeBytes(at: rowID) }
    var modifiedTime: TimeInterval { store.modifiedTime(at: rowID) }
    var createdTime: TimeInterval? { store.createdTime(at: rowID) }
    var isDirectory: Bool { store.isDirectory(at: rowID) }
    var isHidden: Bool { store.isHidden(at: rowID) }
    var volumeName: String { store.volumeName(at: rowID) }
    var normalizedName: String { store.normalizedName(at: rowID) }
    var normalizedPath: String { store.normalizedPath(at: rowID) }
    var rootPath: String? { store.rootPath(at: rowID) }

    func materializedRecord() -> FileRecord {
        store.record(at: rowID)
    }
}

extension RecordStore {
    var mappedByteSize: Int { 0 }
    var heapPageCount: Int { 0 }
    var overlayCount: Int { 0 }
    var hasColumnarSidecars: Bool { false }
    var storedVisibleCount: Int? { nil }
    var storedResultCount: Int? { nil }
    var storedRootAttribution: RootAttributionTable? { nil }
    var schemaVersion: Int { 0 }

    func view(at index: Int) -> RecordSearchView {
        RecordSearchView(store: self, rowID: index)
    }

    func allRecords() -> [FileRecord] {
        (0..<count).map { record(at: $0) }
    }

    func recordID(at index: Int) -> UInt64 { record(at: index).id }
    func path(at index: Int) -> String { record(at: index).path }
    func name(at index: Int) -> String { record(at: index).name }
    func directoryPath(at index: Int) -> String { record(at: index).directoryPath }
    func fileExtension(at index: Int) -> String { record(at: index).fileExtension }
    func sizeBytes(at index: Int) -> UInt64 { record(at: index).sizeBytes }
    func modifiedTime(at index: Int) -> TimeInterval { record(at: index).modifiedTime }
    func createdTime(at index: Int) -> TimeInterval? { record(at: index).createdTime }
    func isDirectory(at index: Int) -> Bool { record(at: index).isDirectory }
    func isHidden(at index: Int) -> Bool { record(at: index).isHidden }
    func volumeName(at index: Int) -> String { record(at: index).volumeName }
    func normalizedName(at index: Int) -> String { record(at: index).normalizedName }
    func normalizedPath(at index: Int) -> String { record(at: index).normalizedPath }
    func parentRowID(at index: Int) -> Int? {
        let record = record(at: index)
        guard record.directoryPath != record.path else { return nil }
        return rowID(forPath: record.directoryPath)
    }
    func subtreeEnd(at index: Int) -> Int { index + 1 }
    func depth(at index: Int) -> Int {
        let path = path(at: index)
        return path.split(separator: "/").count
    }
    func rootID(at index: Int) -> UInt16? { nil }
    func rootPath(at index: Int) -> String? {
        guard let rootID = rootID(at: index) else { return nil }
        return storedRootAttribution?.rootPath(for: rootID)
    }
    func isResultRow(at index: Int) -> Bool { true }
    func isVirtual(at index: Int) -> Bool { false }

    func isVisible(at index: Int) -> Bool {
        guard isResultRow(at: index) else { return false }
        var cache: [Int: Bool] = [:]
        return !isHiddenInPath(at: index, cache: &cache)
    }

    func normalizedPath(at index: Int, contains token: String, cache: inout [Int: Bool]) -> Bool {
        if let cached = cache[index] {
            return cached
        }

        let containsToken = normalizedPath(at: index).contains(token)
        if isDirectory(at: index) {
            cache[index] = containsToken
        }
        return containsToken
    }

    func normalizedName(at index: Int, contains token: String) -> Bool {
        normalizedName(at: index).contains(token)
    }

    func normalizedName(at index: Int, contains tokenBytes: [UInt8]) -> Bool {
        normalizedName(at: index).contains(String(decoding: tokenBytes, as: UTF8.self))
    }

    func isHiddenInPath(at index: Int, cache: inout [Int: Bool]) -> Bool {
        if let cached = cache[index] {
            return cached
        }

        let record = record(at: index)
        let parent = parentRowID(at: index)
        let hidden = record.isHidden
            || (parent.map { $0 != index && isHiddenInPath(at: $0, cache: &cache) } ?? false)
        if record.isDirectory || parent == nil {
            cache[index] = hidden
        }
        return hidden
    }
}

final class EmptyRecordStore: RecordStore {
    static let shared = EmptyRecordStore()

    let count = 0
    let kind = RecordStoreKind.empty

    private init() {}

    func record(at index: Int) -> FileRecord {
        preconditionFailure("Record index \(index) is out of bounds")
    }

    func rowID(forPath path: String) -> Int? {
        nil
    }
}

final class HeapPagedRecordStore: RecordStore {
    static let pageSize = 4_096

    let kind = RecordStoreKind.heapPaged
    let pages: [[FileRecord]]
    private let pathIndex: [String: Int]?
    private let rootIDs: [UInt16]?
    let storedRootAttribution: RootAttributionTable?
    let count: Int

    var heapPageCount: Int { pages.count }

    init(records: [FileRecord], buildsPathIndex: Bool = true, roots: [String] = []) {
        var builtPages: [[FileRecord]] = []
        builtPages.reserveCapacity((records.count + Self.pageSize - 1) / Self.pageSize)

        var start = 0
        while start < records.count {
            let end = min(start + Self.pageSize, records.count)
            builtPages.append(Array(records[start..<end]))
            start = end
        }

        self.pages = builtPages
        self.count = records.count
        if buildsPathIndex {
            self.pathIndex = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($0.element.path, $0.offset) })
        } else {
            self.pathIndex = nil
        }
        let attribution = try? RootAttributionTable.build(roots: roots, rowCount: records.count) { index in
            let record = records[index]
            return RootAttributionInput(
                path: record.path,
                isResultRow: true,
                isDirectory: record.isDirectory,
                isHidden: record.isHidden,
                sizeBytes: record.sizeBytes
            )
        }
        self.rootIDs = attribution?.rootIDs
        self.storedRootAttribution = attribution?.table
    }

    fileprivate init(pages: [[FileRecord]], count: Int, pathIndex: [String: Int]?, roots: [String]) {
        self.pages = pages
        self.count = count
        self.pathIndex = pathIndex
        let attribution = try? RootAttributionTable.build(roots: roots, rowCount: count) { index in
            let record = pages[index / Self.pageSize][index % Self.pageSize]
            return RootAttributionInput(
                path: record.path,
                isResultRow: true,
                isDirectory: record.isDirectory,
                isHidden: record.isHidden,
                sizeBytes: record.sizeBytes
            )
        }
        self.rootIDs = attribution?.rootIDs
        self.storedRootAttribution = attribution?.table
    }

    func record(at index: Int) -> FileRecord {
        precondition(index >= 0 && index < count, "Record index \(index) is out of bounds")
        return pages[index / Self.pageSize][index % Self.pageSize]
    }

    func rowID(forPath path: String) -> Int? {
        if let pathIndex {
            return pathIndex[path]
        }

        for row in 0..<count where record(at: row).path == path {
            return row
        }
        return nil
    }

    func recordID(at index: Int) -> UInt64 { record(at: index).id }

    func rootID(at index: Int) -> UInt16? {
        guard let rootIDs, index >= 0, index < rootIDs.count else { return nil }
        let rootID = rootIDs[index]
        return rootID == RootAttributionTable.unassignedRootID ? nil : rootID
    }

    func rootPath(at index: Int) -> String? {
        guard let rootID = rootID(at: index) else { return nil }
        return storedRootAttribution?.rootPath(for: rootID)
    }
}

extension HeapPagedRecordStore {
    final class Builder: @unchecked Sendable {
        private var sealedPages: [[FileRecord]] = []
        private var currentPage: [FileRecord] = []
        private var pathIndex: [String: Int] = [:]
        private var recordCount = 0
        private let roots: [String]

        var count: Int { recordCount }

        init(reservedCapacity: Int, roots: [String] = []) {
            self.roots = roots
            currentPage.reserveCapacity(HeapPagedRecordStore.pageSize)
            pathIndex.reserveCapacity(reservedCapacity)
        }

        func append(_ record: FileRecord) {
            if let existing = pathIndex[record.path] {
                replace(at: existing, with: record)
                return
            }

            if currentPage.count == HeapPagedRecordStore.pageSize {
                sealedPages.append(currentPage)
                currentPage = []
                currentPage.reserveCapacity(HeapPagedRecordStore.pageSize)
            }

            currentPage.append(record)
            pathIndex[record.path] = recordCount
            recordCount += 1
        }

        func append(contentsOf records: [FileRecord]) {
            for record in records {
                append(record)
            }
        }

        func snapshot(includesPathIndex: Bool = false) -> HeapPagedRecordStore {
            var pages = sealedPages
            if !currentPage.isEmpty {
                pages.append(currentPage)
            }
            return HeapPagedRecordStore(
                pages: pages,
                count: recordCount,
                pathIndex: includesPathIndex ? pathIndex : nil,
                roots: roots
            )
        }

        func allRecords() -> [FileRecord] {
            snapshot(includesPathIndex: true).allRecords()
        }

        private func replace(at index: Int, with record: FileRecord) {
            if index < sealedPages.count * HeapPagedRecordStore.pageSize {
                sealedPages[index / HeapPagedRecordStore.pageSize][index % HeapPagedRecordStore.pageSize] = record
            } else {
                currentPage[index - sealedPages.count * HeapPagedRecordStore.pageSize] = record
            }
        }
    }
}

final class OverlayRecordStore: RecordStore {
    let kind = RecordStoreKind.overlay

    private let base: RecordStore
    private let upserts: [FileRecord]
    private let deletedRows: Set<Int>
    private let visibleBaseRows: [Int]
    private let pathToOverlay: [String: Int]
    private let resultCount: Int
    private let rootAttribution: RootAttributionTable?

    var count: Int { visibleBaseRows.count + upserts.count }
    var mappedByteSize: Int { base.mappedByteSize }
    var heapPageCount: Int { base.heapPageCount }
    var overlayCount: Int { upserts.count + deletedRows.count }
    var hasColumnarSidecars: Bool { base.hasColumnarSidecars }
    var storedResultCount: Int? { resultCount }
    var storedRootAttribution: RootAttributionTable? { rootAttribution }
    var schemaVersion: Int { base.schemaVersion }

    init(base: RecordStore, upserts: [FileRecord], deletedRows: Set<Int>) {
        self.base = base
        self.upserts = upserts
        self.deletedRows = deletedRows
        self.visibleBaseRows = (0..<base.count).filter { !deletedRows.contains($0) }
        self.pathToOverlay = Dictionary(uniqueKeysWithValues: upserts.enumerated().map { ($0.element.path, base.count + $0.offset) })
        let baseResultCount = base.storedResultCount ?? (0..<base.count).filter { base.isResultRow(at: $0) }.count
        let deletedResultCount = deletedRows.filter { base.isResultRow(at: $0) }.count
        self.resultCount = max(0, baseResultCount - deletedResultCount) + upserts.count
        self.rootAttribution = Self.adjustedRootAttribution(base: base, upserts: upserts, deletedRows: deletedRows)
    }

    func record(at index: Int) -> FileRecord {
        if index < visibleBaseRows.count {
            return base.record(at: visibleBaseRows[index])
        }
        return upserts[index - visibleBaseRows.count]
    }

    func allRecords() -> [FileRecord] {
        var records = base.allRecords()
        if !deletedRows.isEmpty {
            let deletedIDs = Set(deletedRows.map { base.recordID(at: $0) })
            records.removeAll { deletedIDs.contains($0.id) }
        }
        records.append(contentsOf: upserts)
        return records
    }

    func recordID(at index: Int) -> UInt64 {
        withBaseRowOrUpsert(at: index, baseValue: { base.recordID(at: $0) }, upsertValue: \.id)
    }

    func path(at index: Int) -> String {
        withBaseRowOrUpsert(at: index, baseValue: { base.path(at: $0) }, upsertValue: \.path)
    }

    func name(at index: Int) -> String {
        withBaseRowOrUpsert(at: index, baseValue: { base.name(at: $0) }, upsertValue: \.name)
    }

    func directoryPath(at index: Int) -> String {
        withBaseRowOrUpsert(at: index, baseValue: { base.directoryPath(at: $0) }, upsertValue: \.directoryPath)
    }

    func fileExtension(at index: Int) -> String {
        withBaseRowOrUpsert(at: index, baseValue: { base.fileExtension(at: $0) }, upsertValue: \.fileExtension)
    }

    func sizeBytes(at index: Int) -> UInt64 {
        withBaseRowOrUpsert(at: index, baseValue: { base.sizeBytes(at: $0) }, upsertValue: \.sizeBytes)
    }

    func modifiedTime(at index: Int) -> TimeInterval {
        withBaseRowOrUpsert(at: index, baseValue: { base.modifiedTime(at: $0) }, upsertValue: \.modifiedTime)
    }

    func createdTime(at index: Int) -> TimeInterval? {
        withBaseRowOrUpsert(at: index, baseValue: { base.createdTime(at: $0) }, upsertValue: \.createdTime)
    }

    func isDirectory(at index: Int) -> Bool {
        withBaseRowOrUpsert(at: index, baseValue: { base.isDirectory(at: $0) }, upsertValue: \.isDirectory)
    }

    func isHidden(at index: Int) -> Bool {
        withBaseRowOrUpsert(at: index, baseValue: { base.isHidden(at: $0) }, upsertValue: \.isHidden)
    }

    func volumeName(at index: Int) -> String {
        withBaseRowOrUpsert(at: index, baseValue: { base.volumeName(at: $0) }, upsertValue: \.volumeName)
    }

    func normalizedName(at index: Int) -> String {
        withBaseRowOrUpsert(at: index, baseValue: { base.normalizedName(at: $0) }, upsertValue: \.normalizedName)
    }

    func normalizedPath(at index: Int) -> String {
        withBaseRowOrUpsert(at: index, baseValue: { base.normalizedPath(at: $0) }, upsertValue: \.normalizedPath)
    }

    func parentRowID(at index: Int) -> Int? {
        if index < visibleBaseRows.count {
            guard let parent = base.parentRowID(at: visibleBaseRows[index]) else { return nil }
            return visibleIndex(forBaseRow: parent)
        }
        return rowID(forPath: upserts[index - visibleBaseRows.count].directoryPath)
    }

    func subtreeEnd(at index: Int) -> Int {
        guard index < visibleBaseRows.count else { return index + 1 }
        return visibleLowerBound(forBaseRowAtLeast: base.subtreeEnd(at: visibleBaseRows[index]))
    }

    func depth(at index: Int) -> Int {
        if index < visibleBaseRows.count {
            return base.depth(at: visibleBaseRows[index])
        }
        return upserts[index - visibleBaseRows.count].path.split(separator: "/").count
    }

    func isResultRow(at index: Int) -> Bool {
        if index < visibleBaseRows.count {
            return base.isResultRow(at: visibleBaseRows[index])
        }
        return true
    }

    func isVirtual(at index: Int) -> Bool {
        if index < visibleBaseRows.count {
            return base.isVirtual(at: visibleBaseRows[index])
        }
        return false
    }

    func isVisible(at index: Int) -> Bool {
        if index < visibleBaseRows.count {
            return base.isVisible(at: visibleBaseRows[index])
        }
        return !upserts[index - visibleBaseRows.count].isHidden
    }

    func isHiddenInPath(at index: Int, cache _: inout [Int: Bool]) -> Bool {
        !isVisible(at: index)
    }

    func rowID(forPath path: String) -> Int? {
        if let row = pathToOverlay[path] {
            return visibleBaseRows.count + (row - base.count)
        }
        guard let row = base.rowID(forPath: path), !deletedRows.contains(row) else {
            return nil
        }
        return visibleIndex(forBaseRow: row)
    }

    func rootID(at index: Int) -> UInt16? {
        if index < visibleBaseRows.count {
            return base.rootID(at: visibleBaseRows[index])
        }
        guard let rootAttribution else { return nil }
        return rootAttribution.rootID(for: upserts[index - visibleBaseRows.count].path)
    }

    func rootPath(at index: Int) -> String? {
        guard let rootID = rootID(at: index) else { return nil }
        return rootAttribution?.rootPath(for: rootID) ?? base.storedRootAttribution?.rootPath(for: rootID)
    }

    private func withBaseRowOrUpsert<Value>(
        at index: Int,
        baseValue: (Int) -> Value,
        upsertValue: KeyPath<FileRecord, Value>
    ) -> Value {
        precondition(index >= 0 && index < count, "Record index \(index) is out of bounds")
        if index < visibleBaseRows.count {
            return baseValue(visibleBaseRows[index])
        }
        return upserts[index - visibleBaseRows.count][keyPath: upsertValue]
    }

    private func visibleIndex(forBaseRow row: Int) -> Int? {
        let index = visibleLowerBound(forBaseRowAtLeast: row)
        return index < visibleBaseRows.count && visibleBaseRows[index] == row ? index : nil
    }

    private func visibleLowerBound(forBaseRowAtLeast row: Int) -> Int {
        var lower = 0
        var upper = visibleBaseRows.count

        while lower < upper {
            let middle = (lower + upper) / 2
            let candidate = visibleBaseRows[middle]
            if candidate < row {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        return lower
    }

    private static func adjustedRootAttribution(
        base: RecordStore,
        upserts: [FileRecord],
        deletedRows: Set<Int>
    ) -> RootAttributionTable? {
        guard var table = base.storedRootAttribution else { return nil }

        for rowID in deletedRows {
            guard let rootID = base.rootID(at: rowID) else { continue }
            table.subtract(
                RootAttributionInput(
                    path: base.path(at: rowID),
                    isResultRow: base.isResultRow(at: rowID),
                    isDirectory: base.isDirectory(at: rowID),
                    isHidden: base.isHidden(at: rowID),
                    sizeBytes: base.sizeBytes(at: rowID)
                ),
                from: rootID
            )
        }

        for record in upserts {
            guard let rootID = table.rootID(for: record.path) else { continue }
            table.add(
                RootAttributionInput(
                    path: record.path,
                    isResultRow: true,
                    isDirectory: record.isDirectory,
                    isHidden: record.isHidden,
                    sizeBytes: record.sizeBytes
                ),
                to: rootID
            )
        }

        return table
    }
}

final class ReplacingRecordStore: RecordStore {
    let kind = RecordStoreKind.overlay

    private let base: RecordStore
    private let replacements: [Int: FileRecord]
    private let rootAttribution: RootAttributionTable?

    var count: Int { base.count }
    var mappedByteSize: Int { base.mappedByteSize }
    var heapPageCount: Int { base.heapPageCount }
    var overlayCount: Int { replacements.count }
    var hasColumnarSidecars: Bool { base.hasColumnarSidecars }
    var storedResultCount: Int? { base.storedResultCount }
    var storedRootAttribution: RootAttributionTable? { rootAttribution }
    var schemaVersion: Int { base.schemaVersion }

    init(base: RecordStore, replacements: [Int: FileRecord]) {
        self.base = base
        self.replacements = replacements
        self.rootAttribution = Self.adjustedRootAttribution(base: base, replacements: replacements)
    }

    func record(at index: Int) -> FileRecord {
        replacements[index] ?? base.record(at: index)
    }

    func allRecords() -> [FileRecord] {
        guard !replacements.isEmpty else { return base.allRecords() }

        let replacementsByID = Dictionary(
            uniqueKeysWithValues: replacements.map { rowID, record in
                (base.recordID(at: rowID), record)
            }
        )
        return base.allRecords().map { record in
            replacementsByID[record.id] ?? record
        }
    }

    func recordID(at index: Int) -> UInt64 {
        replacements[index]?.id ?? base.recordID(at: index)
    }

    func path(at index: Int) -> String {
        replacements[index]?.path ?? base.path(at: index)
    }

    func name(at index: Int) -> String {
        replacements[index]?.name ?? base.name(at: index)
    }

    func directoryPath(at index: Int) -> String {
        replacements[index]?.directoryPath ?? base.directoryPath(at: index)
    }

    func fileExtension(at index: Int) -> String {
        replacements[index]?.fileExtension ?? base.fileExtension(at: index)
    }

    func sizeBytes(at index: Int) -> UInt64 {
        replacements[index]?.sizeBytes ?? base.sizeBytes(at: index)
    }

    func modifiedTime(at index: Int) -> TimeInterval {
        replacements[index]?.modifiedTime ?? base.modifiedTime(at: index)
    }

    func createdTime(at index: Int) -> TimeInterval? {
        replacements[index]?.createdTime ?? base.createdTime(at: index)
    }

    func isDirectory(at index: Int) -> Bool {
        replacements[index]?.isDirectory ?? base.isDirectory(at: index)
    }

    func isHidden(at index: Int) -> Bool {
        replacements[index]?.isHidden ?? base.isHidden(at: index)
    }

    func volumeName(at index: Int) -> String {
        replacements[index]?.volumeName ?? base.volumeName(at: index)
    }

    func normalizedName(at index: Int) -> String {
        replacements[index]?.normalizedName ?? base.normalizedName(at: index)
    }

    func normalizedPath(at index: Int) -> String {
        replacements[index]?.normalizedPath ?? base.normalizedPath(at: index)
    }

    func parentRowID(at index: Int) -> Int? {
        base.parentRowID(at: index)
    }

    func subtreeEnd(at index: Int) -> Int {
        base.subtreeEnd(at: index)
    }

    func depth(at index: Int) -> Int {
        base.depth(at: index)
    }

    func isResultRow(at index: Int) -> Bool {
        base.isResultRow(at: index)
    }

    func isVirtual(at index: Int) -> Bool {
        base.isVirtual(at: index)
    }

    func isVisible(at index: Int) -> Bool {
        guard isResultRow(at: index) else {
            return false
        }
        guard let replacement = replacements[index] else {
            return base.isVisible(at: index)
        }

        if replacement.isHidden {
            return false
        }

        guard let parent = base.parentRowID(at: index), parent != index else {
            return true
        }

        return base.isVisible(at: parent)
    }

    func normalizedPath(at index: Int, contains token: String, cache: inout [Int: Bool]) -> Bool {
        guard replacements[index] != nil else {
            return base.normalizedPath(at: index, contains: token, cache: &cache)
        }
        return normalizedPath(at: index).contains(token)
    }

    func normalizedName(at index: Int, contains token: String) -> Bool {
        guard let replacement = replacements[index] else {
            return base.normalizedName(at: index, contains: token)
        }
        return replacement.normalizedName.contains(token)
    }

    func normalizedName(at index: Int, contains tokenBytes: [UInt8]) -> Bool {
        guard let replacement = replacements[index] else {
            return base.normalizedName(at: index, contains: tokenBytes)
        }
        return replacement.normalizedName.contains(String(decoding: tokenBytes, as: UTF8.self))
    }

    func isHiddenInPath(at index: Int, cache: inout [Int: Bool]) -> Bool {
        !isVisible(at: index)
    }

    func rowID(forPath path: String) -> Int? {
        base.rowID(forPath: path)
    }

    func rootID(at index: Int) -> UInt16? {
        base.rootID(at: index)
    }

    func rootPath(at index: Int) -> String? {
        guard let rootID = rootID(at: index) else { return nil }
        return rootAttribution?.rootPath(for: rootID) ?? base.rootPath(at: index)
    }

    private static func adjustedRootAttribution(
        base: RecordStore,
        replacements: [Int: FileRecord]
    ) -> RootAttributionTable? {
        guard var table = base.storedRootAttribution else { return nil }

        for (rowID, replacement) in replacements {
            guard let rootID = base.rootID(at: rowID) else { continue }
            table.subtract(
                RootAttributionInput(
                    path: base.path(at: rowID),
                    isResultRow: base.isResultRow(at: rowID),
                    isDirectory: base.isDirectory(at: rowID),
                    isHidden: base.isHidden(at: rowID),
                    sizeBytes: base.sizeBytes(at: rowID)
                ),
                from: rootID
            )
            table.add(
                RootAttributionInput(
                    path: replacement.path,
                    isResultRow: base.isResultRow(at: rowID),
                    isDirectory: replacement.isDirectory,
                    isHidden: replacement.isHidden,
                    sizeBytes: replacement.sizeBytes
                ),
                to: rootID
            )
        }

        return table
    }
}

final class MappedRecordStore: RecordStore {
    let kind = RecordStoreKind.mapped

    private static let recordsMagic: UInt64 = 0x3452575441545441 // ATTRW4 little-endian bytes.
    private static let recordsVersion: UInt32 = 1
    private static let pathLookupMagic: UInt64 = 0x344b4c5441545441 // ATTLK4 little-endian bytes.
    private static let rowSize = 104
    private static let recordsHeaderSize = 32
    private static let pathLookupHeaderSize = 24
    private static let pathLookupEntrySize = 16
    private static let virtualFlag: UInt8 = 1 << 3

    private struct Row {
        let id: UInt64
        let parent: Int32
        let flags: UInt32
        let sizeBytes: UInt64
        let modifiedBits: UInt64
        let createdBits: UInt64
        let nameOffset: UInt64
        let nameLength: UInt32
        let normalizedNameOffset: UInt64
        let normalizedNameLength: UInt32
        let baseDirectoryOffset: UInt64
        let baseDirectoryLength: UInt32
        let normalizedBaseDirectoryOffset: UInt64
        let normalizedBaseDirectoryLength: UInt32
        let extensionID: UInt32
        let volumeID: UInt32
    }

    private struct PathLookupEntry {
        let hash: UInt64
        let rowID: Int32
    }

    let count: Int
    private let recordsData: Data
    private let stringsData: Data
    private let pathLookupData: Data
    private let parentData: Data
    private let flagsData: Data
    private let visibleData: Data
    private let subtreeEndData: Data?
    private let depthData: Data?
    private let rootIDData: Data
    private let rootsByteSize: Int
    private let extensions: [String]
    private let volumes: [String]
    let storedRootAttribution: RootAttributionTable?
    private let visibleCount: Int
    private let resultCount: Int
    private let cache = PathMaterializationCache(limit: 16_384)
    let schemaVersion: Int

    var mappedByteSize: Int {
        recordsData.count + stringsData.count + pathLookupData.count
            + parentData.count + flagsData.count + visibleData.count
            + (subtreeEndData?.count ?? 0) + (depthData?.count ?? 0)
            + rootIDData.count + rootsByteSize
    }
    var hasColumnarSidecars: Bool { true }
    var storedVisibleCount: Int? { visibleCount }
    var storedResultCount: Int? { resultCount }

    init(packageURL: URL, schemaVersion: Int = SnapshotLayout.schemaVersion) throws {
        self.schemaVersion = schemaVersion
        let recordsURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.records, isDirectory: false)
        let stringsURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.strings, isDirectory: false)
        let internsURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.interns, isDirectory: false)
        let lookupURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.pathLookup, isDirectory: false)
        let parentURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.parent, isDirectory: false)
        let flagsURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.flags, isDirectory: false)
        let visibleURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.visible, isDirectory: false)
        let subtreeEndURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.subtreeEnd, isDirectory: false)
        let depthURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.depth, isDirectory: false)
        let rootIDURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.rootID, isDirectory: false)
        let rootsURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.roots, isDirectory: false)

        self.recordsData = try Data(contentsOf: recordsURL, options: [.mappedIfSafe])
        self.stringsData = try Data(contentsOf: stringsURL, options: [.mappedIfSafe])
        self.pathLookupData = try Data(contentsOf: lookupURL, options: [.mappedIfSafe])
        self.parentData = try Data(contentsOf: parentURL, options: [.mappedIfSafe])
        self.flagsData = try Data(contentsOf: flagsURL, options: [.mappedIfSafe])
        self.visibleData = try Data(contentsOf: visibleURL, options: [.mappedIfSafe])
        self.subtreeEndData = (try? Data(contentsOf: subtreeEndURL, options: [.mappedIfSafe]))
        self.depthData = (try? Data(contentsOf: depthURL, options: [.mappedIfSafe]))
        self.rootIDData = try Data(contentsOf: rootIDURL, options: [.mappedIfSafe])
        let rootsData = try Data(contentsOf: rootsURL)
        self.rootsByteSize = rootsData.count
        let rootAttribution = try JSONDecoder().decode(RootAttributionTable.self, from: rootsData)
        guard rootAttribution.isValid else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.storedRootAttribution = rootAttribution

        guard
            recordsData.count >= Self.recordsHeaderSize,
            recordsData.readUInt64LE(at: 0) == Self.recordsMagic,
            recordsData.readUInt32LE(at: 8) == Self.recordsVersion
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let rowCount = Int(recordsData.readUInt64LE(at: 16))
        guard recordsData.count == Self.recordsHeaderSize + rowCount * Self.rowSize else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.count = rowCount
        guard
            parentData.count == rowCount * 4,
            flagsData.count == rowCount,
            visibleData.count == Self.bitsetByteCount(for: rowCount),
            rootIDData.count == rowCount * 2
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let subtreeEndData, subtreeEndData.count != rowCount * 4 {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let depthData, depthData.count != rowCount * 2 {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.visibleCount = Self.countVisibleRows(in: visibleData, rowCount: rowCount)
        self.resultCount = Self.countResultRows(flagsData: flagsData, rowCount: rowCount)
        guard Self.rootIDsAreValid(rootIDData, rowCount: rowCount, rootCount: rootAttribution.roots.count) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        guard
            pathLookupData.count >= Self.pathLookupHeaderSize,
            pathLookupData.readUInt64LE(at: 0) == Self.pathLookupMagic
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let lookupCount = Int(pathLookupData.readUInt64LE(at: 16))
        guard pathLookupData.count == Self.pathLookupHeaderSize + lookupCount * Self.pathLookupEntrySize else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let interns = try Self.loadInterns(from: internsURL)
        self.extensions = interns.extensions
        self.volumes = interns.volumes
    }

    func record(at index: Int) -> FileRecord {
        let row = readRow(index)
        let path = path(at: index)
        let directoryPath = directoryPath(at: index)
        let normalizedName = string(offset: row.normalizedNameOffset, length: row.normalizedNameLength)
        let normalizedPath = normalizedPath(at: index)

        return FileRecord(
            id: row.id,
            path: path,
            name: string(offset: row.nameOffset, length: row.nameLength),
            directoryPath: directoryPath,
            fileExtension: intern(extensions, id: row.extensionID),
            sizeBytes: row.sizeBytes,
            modifiedTime: TimeInterval(bitPattern: row.modifiedBits),
            createdTime: row.flags & 4 == 0 ? nil : TimeInterval(bitPattern: row.createdBits),
            isDirectory: row.flags & 1 != 0,
            isHidden: row.flags & 2 != 0,
            volumeName: intern(volumes, id: row.volumeID),
            normalizedName: normalizedName,
            normalizedPath: normalizedPath
        )
    }

    func rowID(forPath path: String) -> Int? {
        let hash = FileRecord.stableID(for: path)
        let lookupCount = Int(pathLookupData.readUInt64LE(at: 16))
        var low = 0
        var high = lookupCount

        while low < high {
            let mid = (low + high) / 2
            let entry = readLookupEntry(mid)
            if entry.hash < hash {
                low = mid + 1
            } else {
                high = mid
            }
        }

        var index = low
        while index < lookupCount {
            let entry = readLookupEntry(index)
            guard entry.hash == hash else { break }
            let rowID = Int(entry.rowID)
            if rowID >= 0, rowID < count, self.path(at: rowID) == path {
                return rowID
            }
            index += 1
        }

        return nil
    }

    func allRecords() -> [FileRecord] {
        var records: [FileRecord] = []
        records.reserveCapacity(resultCount)

        var materializedPaths = Array<String?>(repeating: nil, count: count)
        var materializedNormalizedPaths = Array<String?>(repeating: nil, count: count)

        for rowID in 0..<count {
            let row = readRow(rowID)
            let name = string(offset: row.nameOffset, length: row.nameLength)
            let normalizedName = string(offset: row.normalizedNameOffset, length: row.normalizedNameLength)
            let directoryPath: String
            let normalizedDirectoryPath: String

            if row.parent >= 0 {
                let parent = Int(row.parent)
                directoryPath = parent < materializedPaths.count
                    ? materializedPaths[parent] ?? path(at: parent)
                    : path(at: parent)
                normalizedDirectoryPath = parent < materializedNormalizedPaths.count
                    ? materializedNormalizedPaths[parent] ?? normalizedPath(at: parent)
                    : normalizedPath(at: parent)
            } else {
                directoryPath = string(offset: row.baseDirectoryOffset, length: row.baseDirectoryLength)
                normalizedDirectoryPath = string(
                    offset: row.normalizedBaseDirectoryOffset,
                    length: row.normalizedBaseDirectoryLength
                )
            }

            let path = Self.join(directory: directoryPath, name: name)
            let normalizedPath = Self.join(directory: normalizedDirectoryPath, name: normalizedName)
            materializedPaths[rowID] = path
            materializedNormalizedPaths[rowID] = normalizedPath

            guard row.flags & UInt32(Self.virtualFlag) == 0 else { continue }
            records.append(FileRecord(
                id: row.id,
                path: path,
                name: name,
                directoryPath: directoryPath,
                fileExtension: intern(extensions, id: row.extensionID),
                sizeBytes: row.sizeBytes,
                modifiedTime: TimeInterval(bitPattern: row.modifiedBits),
                createdTime: row.flags & 4 == 0 ? nil : TimeInterval(bitPattern: row.createdBits),
                isDirectory: row.flags & 1 != 0,
                isHidden: row.flags & 2 != 0,
                volumeName: intern(volumes, id: row.volumeID),
                normalizedName: normalizedName,
                normalizedPath: normalizedPath
            ))
        }
        return records
    }

    private static func join(directory: String, name: String) -> String {
        if directory.isEmpty || directory == "/" {
            return directory == "/" ? "/\(name)" : name
        }
        return "\(directory)/\(name)"
    }

    func recordID(at index: Int) -> UInt64 { readRow(index).id }
    func parentRowID(at index: Int) -> Int? {
        let parent = parentData.readInt32LE(at: columnOffset(for: index, stride: 4))
        return parent >= 0 ? Int(parent) : nil
    }

    func subtreeEnd(at index: Int) -> Int {
        guard let subtreeEndData else { return index + 1 }
        let end = Int(subtreeEndData.readInt32LE(at: columnOffset(for: index, stride: 4)))
        guard end > index, end <= count else { return index + 1 }
        return end
    }

    func depth(at index: Int) -> Int {
        guard let depthData else {
            return path(at: index).split(separator: "/").count
        }
        return Int(depthData.readUInt16LE(at: columnOffset(for: index, stride: 2)))
    }

    func name(at index: Int) -> String {
        let row = readRow(index)
        return string(offset: row.nameOffset, length: row.nameLength)
    }

    func directoryPath(at index: Int) -> String {
        if let cached = cache.directoryPath(for: index) {
            return cached
        }

        let row = readRow(index)
        let value: String
        if row.parent >= 0 {
            value = path(at: Int(row.parent))
        } else {
            value = string(offset: row.baseDirectoryOffset, length: row.baseDirectoryLength)
        }
        cache.setDirectoryPath(value, for: index)
        return value
    }

    func path(at index: Int) -> String {
        if let cached = cache.path(for: index) {
            return cached
        }

        let row = readRow(index)
        let name = string(offset: row.nameOffset, length: row.nameLength)
        let directory = directoryPath(at: index)
        let value: String
        if directory.isEmpty || directory == "/" {
            value = directory == "/" ? "/\(name)" : name
        } else {
            value = "\(directory)/\(name)"
        }
        cache.setPath(value, for: index)
        return value
    }

    func fileExtension(at index: Int) -> String { intern(extensions, id: readRow(index).extensionID) }
    func sizeBytes(at index: Int) -> UInt64 { readRow(index).sizeBytes }
    func modifiedTime(at index: Int) -> TimeInterval { TimeInterval(bitPattern: readRow(index).modifiedBits) }
    func createdTime(at index: Int) -> TimeInterval? {
        let row = readRow(index)
        return row.flags & 4 == 0 ? nil : TimeInterval(bitPattern: row.createdBits)
    }
    func isDirectory(at index: Int) -> Bool { flagsByte(at: index) & 1 != 0 }
    func isHidden(at index: Int) -> Bool { flagsByte(at: index) & 2 != 0 }
    func isVirtual(at index: Int) -> Bool { flagsByte(at: index) & Self.virtualFlag != 0 }
    func isResultRow(at index: Int) -> Bool { !isVirtual(at: index) }
    func isVisible(at index: Int) -> Bool {
        precondition(index >= 0 && index < count, "Record index \(index) is out of bounds")
        return isResultRow(at: index) && Self.bitsetValue(in: visibleData, at: index)
    }
    func volumeName(at index: Int) -> String { intern(volumes, id: readRow(index).volumeID) }
    func rootID(at index: Int) -> UInt16? {
        let rootID = rootIDData.readUInt16LE(at: columnOffset(for: index, stride: 2))
        return rootID == RootAttributionTable.unassignedRootID ? nil : rootID
    }

    func rootPath(at index: Int) -> String? {
        guard let rootID = rootID(at: index) else { return nil }
        return storedRootAttribution?.rootPath(for: rootID)
    }

    func normalizedName(at index: Int) -> String {
        let row = readRow(index)
        return string(offset: row.normalizedNameOffset, length: row.normalizedNameLength)
    }
    func normalizedName(at index: Int, contains token: String) -> Bool {
        guard !token.isEmpty else { return false }
        return normalizedName(at: index, contains: Array(token.utf8))
    }

    func normalizedName(at index: Int, contains tokenBytes: [UInt8]) -> Bool {
        guard !tokenBytes.isEmpty else { return false }
        let offset = rowOffset(for: index)
        let lower = Int(recordsData.readUInt64LE(at: offset + 52))
        let length = Int(recordsData.readUInt32LE(at: offset + 60))
        return stringsData.containsBytes(tokenBytes, in: lower..<(lower + length))
    }
    func normalizedPath(at index: Int) -> String {
        if let cached = cache.normalizedPath(for: index) {
            return cached
        }

        let row = readRow(index)
        let name = string(offset: row.normalizedNameOffset, length: row.normalizedNameLength)
        let directory: String
        if row.parent >= 0 {
            directory = normalizedPath(at: Int(row.parent))
        } else {
            directory = string(offset: row.normalizedBaseDirectoryOffset, length: row.normalizedBaseDirectoryLength)
        }

        let value: String
        if directory.isEmpty || directory == "/" {
            value = directory == "/" ? "/\(name)" : name
        } else {
            value = "\(directory)/\(name)"
        }
        cache.setNormalizedPath(value, for: index)
        return value
    }

    func normalizedPath(at index: Int, contains token: String, cache: inout [Int: Bool]) -> Bool {
        if let cached = cache[index] {
            return cached
        }

        let row = readRow(index)
        let containsToken: Bool
        if string(offset: row.normalizedNameOffset, length: row.normalizedNameLength).contains(token) {
            containsToken = true
        } else if row.parent >= 0 {
            containsToken = normalizedPath(at: Int(row.parent), contains: token, cache: &cache)
        } else {
            containsToken = string(
                offset: row.normalizedBaseDirectoryOffset,
                length: row.normalizedBaseDirectoryLength
            ).contains(token)
        }

        if row.flags & 1 != 0 || row.parent < 0 {
            cache[index] = containsToken
        }
        return containsToken
    }

    func isHiddenInPath(at index: Int, cache: inout [Int: Bool]) -> Bool {
        !isVisible(at: index)
    }

    private func readRow(_ index: Int) -> Row {
        let offset = rowOffset(for: index)
        return Row(
            id: recordsData.readUInt64LE(at: offset),
            parent: recordsData.readInt32LE(at: offset + 8),
            flags: recordsData.readUInt32LE(at: offset + 12),
            sizeBytes: recordsData.readUInt64LE(at: offset + 16),
            modifiedBits: recordsData.readUInt64LE(at: offset + 24),
            createdBits: recordsData.readUInt64LE(at: offset + 32),
            nameOffset: recordsData.readUInt64LE(at: offset + 40),
            nameLength: recordsData.readUInt32LE(at: offset + 48),
            normalizedNameOffset: recordsData.readUInt64LE(at: offset + 52),
            normalizedNameLength: recordsData.readUInt32LE(at: offset + 60),
            baseDirectoryOffset: recordsData.readUInt64LE(at: offset + 64),
            baseDirectoryLength: recordsData.readUInt32LE(at: offset + 72),
            normalizedBaseDirectoryOffset: recordsData.readUInt64LE(at: offset + 76),
            normalizedBaseDirectoryLength: recordsData.readUInt32LE(at: offset + 84),
            extensionID: recordsData.readUInt32LE(at: offset + 88),
            volumeID: recordsData.readUInt32LE(at: offset + 92)
        )
    }

    private func rowOffset(for index: Int) -> Int {
        precondition(index >= 0 && index < count, "Record index \(index) is out of bounds")
        return Self.recordsHeaderSize + index * Self.rowSize
    }

    private func columnOffset(for index: Int, stride: Int) -> Int {
        precondition(index >= 0 && index < count, "Record index \(index) is out of bounds")
        return index * stride
    }

    private func flagsByte(at index: Int) -> UInt8 {
        flagsData[columnOffset(for: index, stride: 1)]
    }

    private func readLookupEntry(_ index: Int) -> PathLookupEntry {
        let offset = Self.pathLookupHeaderSize + index * Self.pathLookupEntrySize
        return PathLookupEntry(
            hash: pathLookupData.readUInt64LE(at: offset),
            rowID: pathLookupData.readInt32LE(at: offset + 8)
        )
    }

    private func string(offset: UInt64, length: UInt32) -> String {
        let lower = Int(offset)
        let upper = lower + Int(length)
        guard lower >= 0, upper <= stringsData.count else {
            return ""
        }
        return String(decoding: stringsData[lower..<upper], as: UTF8.self)
    }

    private func intern(_ values: [String], id: UInt32) -> String {
        let index = Int(id)
        guard index >= 0, index < values.count else {
            return ""
        }
        return values[index]
    }

    private static func loadInterns(from url: URL) throws -> (extensions: [String], volumes: [String]) {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        var offset = 0

        func readStringTable() throws -> [String] {
            guard offset + 4 <= data.count else { throw CocoaError(.fileReadCorruptFile) }
            let count = Int(data.readUInt32LE(at: offset))
            offset += 4

            var values: [String] = []
            values.reserveCapacity(count)
            for _ in 0..<count {
                guard offset + 4 <= data.count else { throw CocoaError(.fileReadCorruptFile) }
                let length = Int(data.readUInt32LE(at: offset))
                offset += 4
                guard offset + length <= data.count else { throw CocoaError(.fileReadCorruptFile) }
                values.append(String(decoding: data[offset..<offset + length], as: UTF8.self))
                offset += length
            }
            return values
        }

        let extensions = try readStringTable()
        let volumes = try readStringTable()
        guard offset == data.count else { throw CocoaError(.fileReadCorruptFile) }
        return (extensions, volumes)
    }

    private struct PackageRow {
        let record: FileRecord
        let isVirtual: Bool
    }

    private static func preparePackageRows(records: [FileRecord], roots: [String]) -> [PackageRow] {
        var rowsByPath: [String: PackageRow] = [:]
        rowsByPath.reserveCapacity(records.count)

        for record in records {
            rowsByPath[record.path] = PackageRow(record: record, isVirtual: false)
        }

        func addVirtualDirectory(_ path: String) {
            guard path != "/", !path.isEmpty, rowsByPath[path] == nil else { return }
            rowsByPath[path] = PackageRow(record: virtualDirectoryRecord(path: path), isVirtual: true)
        }

        for root in roots {
            for ancestor in ancestorPaths(through: root) {
                addVirtualDirectory(ancestor)
            }
        }

        for record in records {
            for ancestor in ancestorPaths(through: record.directoryPath) {
                addVirtualDirectory(ancestor)
            }
        }

        var childrenByParent: [String: [String]] = [:]
        childrenByParent.reserveCapacity(rowsByPath.count)
        for (path, row) in rowsByPath {
            let parent = parentPath(for: row.record)
            let parentKey = parent.flatMap { rowsByPath[$0] == nil ? nil : $0 } ?? ""
            childrenByParent[parentKey, default: []].append(path)
        }

        for key in childrenByParent.keys {
            childrenByParent[key]?.sort()
        }

        var ordered: [PackageRow] = []
        ordered.reserveCapacity(rowsByPath.count)
        var seen = Set<String>()
        seen.reserveCapacity(rowsByPath.count)

        func appendDepthFirst(_ path: String) {
            guard seen.insert(path).inserted, let row = rowsByPath[path] else { return }
            ordered.append(row)
            for child in childrenByParent[path] ?? [] {
                appendDepthFirst(child)
            }
        }

        for rootPath in childrenByParent[""] ?? [] {
            appendDepthFirst(rootPath)
        }

        if ordered.count != rowsByPath.count {
            for path in rowsByPath.keys.sorted() {
                appendDepthFirst(path)
            }
        }

        return ordered
    }

    private static func ancestorPaths(through path: String) -> [String] {
        guard path != "/", !path.isEmpty else { return [] }
        let parts = path.split(separator: "/")
        guard !parts.isEmpty else { return [] }

        var ancestors: [String] = []
        ancestors.reserveCapacity(parts.count)
        var current = ""
        for part in parts {
            current += "/" + part
            ancestors.append(current)
        }
        return ancestors
    }

    private static func parentPath(for record: FileRecord) -> String? {
        guard record.directoryPath != record.path else { return nil }
        return record.directoryPath
    }

    private static func virtualDirectoryRecord(path: String) -> FileRecord {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        let name = url.lastPathComponent.isEmpty ? path : url.lastPathComponent
        return FileRecord(
            id: FileRecord.stableID(for: "att-virtual:\(path)"),
            path: path,
            name: name,
            directoryPath: parent == path ? "/" : parent,
            fileExtension: url.pathExtension.lowercased(),
            sizeBytes: 0,
            modifiedTime: 0,
            createdTime: nil,
            isDirectory: true,
            isHidden: FileRecord.pathIsHidden(path),
            volumeName: "",
            normalizedName: FuzzyMatcher.normalize(name),
            normalizedPath: FuzzyMatcher.normalize(path)
        )
    }

    static func writePackage(
        records: [FileRecord],
        roots: [String],
        exclusionPatterns: [String],
        packageURL: URL,
        savedAt: Date = Date(),
        fileManager: FileManager = .default
    ) throws {
        if fileManager.fileExists(atPath: packageURL.path) {
            try fileManager.removeItem(at: packageURL)
        }
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let packageRows = preparePackageRows(records: records, roots: roots)
        let resultCount = packageRows.reduce(0) { $0 + ($1.isVirtual ? 0 : 1) }
        let rootAttribution = try RootAttributionTable.build(roots: roots, rowCount: packageRows.count) { index in
            let row = packageRows[index]
            return RootAttributionInput(
                path: row.record.path,
                isResultRow: !row.isVirtual,
                isDirectory: row.record.isDirectory,
                isHidden: row.record.isHidden,
                sizeBytes: row.record.sizeBytes
            )
        }

        let manifest = CompactSnapshotManifest(
            schemaVersion: SnapshotLayout.schemaVersion,
            savedAt: savedAt,
            roots: roots,
            exclusionPatterns: exclusionPatterns,
            recordCount: packageRows.count,
            resultCount: resultCount
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: packageURL.appendingPathComponent(SnapshotLayout.FileName.manifest, isDirectory: false), options: .atomic)
        try JSONEncoder().encode(rootAttribution.table).write(
            to: packageURL.appendingPathComponent(SnapshotLayout.FileName.roots, isDirectory: false),
            options: .atomic
        )

        var extensionIDs: [String: UInt32] = ["": 0]
        var volumeIDs: [String: UInt32] = ["": 0]
        for row in packageRows {
            let record = row.record
            if extensionIDs[record.fileExtension] == nil {
                extensionIDs[record.fileExtension] = UInt32(extensionIDs.count)
            }
            if volumeIDs[record.volumeName] == nil {
                volumeIDs[record.volumeName] = UInt32(volumeIDs.count)
            }
        }

        try writeInterns(
            extensions: sortedInterns(extensionIDs),
            volumes: sortedInterns(volumeIDs),
            to: packageURL.appendingPathComponent(SnapshotLayout.FileName.interns, isDirectory: false)
        )

        let stringsURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.strings, isDirectory: false)
        let recordsURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.records, isDirectory: false)
        let lookupURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.pathLookup, isDirectory: false)
        let parentURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.parent, isDirectory: false)
        let flagsURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.flags, isDirectory: false)
        let visibleURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.visible, isDirectory: false)
        let subtreeEndURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.subtreeEnd, isDirectory: false)
        let depthURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.depth, isDirectory: false)
        let rootIDURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.rootID, isDirectory: false)

        guard
            fileManager.createFile(atPath: stringsURL.path, contents: nil),
            fileManager.createFile(atPath: recordsURL.path, contents: nil),
            fileManager.createFile(atPath: lookupURL.path, contents: nil)
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        let stringsHandle = try FileHandle(forWritingTo: stringsURL)
        let recordsHandle = try FileHandle(forWritingTo: recordsURL)
        let lookupHandle = try FileHandle(forWritingTo: lookupURL)
        defer {
            try? stringsHandle.close()
            try? recordsHandle.close()
            try? lookupHandle.close()
        }

        var stringOffset: UInt64 = 0
        func appendString(_ value: String) throws -> (offset: UInt64, length: UInt32) {
            let data = Data(value.utf8)
            let result = (stringOffset, UInt32(data.count))
            try stringsHandle.write(contentsOf: data)
            stringOffset += UInt64(data.count)
            return result
        }

        var pathToRow: [String: Int32] = [:]
        pathToRow.reserveCapacity(packageRows.count)
        for (index, row) in packageRows.enumerated() {
            pathToRow[row.record.path] = Int32(index)
        }

        var header = Data()
        header.appendUInt64LE(Self.recordsMagic)
        header.appendUInt32LE(Self.recordsVersion)
        header.appendUInt32LE(UInt32(Self.rowSize))
        header.appendUInt64LE(UInt64(packageRows.count))
        header.appendUInt64LE(0)
        try recordsHandle.write(contentsOf: header)

        var lookupEntries: [(hash: UInt64, rowID: Int32)] = []
        lookupEntries.reserveCapacity(packageRows.count)
        var parentColumn = Data()
        parentColumn.reserveCapacity(packageRows.count * 4)
        var flagColumn = Data()
        flagColumn.reserveCapacity(packageRows.count)
        var parents: [Int32] = []
        parents.reserveCapacity(packageRows.count)
        var flagBytes: [UInt8] = []
        flagBytes.reserveCapacity(packageRows.count)
        var depths = Array(repeating: UInt16(0), count: packageRows.count)
        var rootIDColumn = Data()
        rootIDColumn.reserveCapacity(packageRows.count * 2)

        for (index, packageRow) in packageRows.enumerated() {
            let record = packageRow.record
            try autoreleasepool {
                let name = try appendString(record.name)
                let normalizedName = try appendString(record.normalizedName)
                let parent = record.directoryPath == record.path ? -1 : (pathToRow[record.directoryPath] ?? -1)
                let baseDirectory: (offset: UInt64, length: UInt32) = parent >= 0 ? (0, 0) : try appendString(record.directoryPath)
                let normalizedDirectory: (offset: UInt64, length: UInt32) = parent >= 0 ? (0, 0) : try appendString(FuzzyMatcher.normalize(record.directoryPath))

                var rowFlags: UInt32 = 0
                if record.isDirectory { rowFlags |= 1 }
                if record.isHidden { rowFlags |= 2 }
                if record.createdTime != nil { rowFlags |= 4 }
                if packageRow.isVirtual { rowFlags |= UInt32(Self.virtualFlag) }
                let packedFlags = UInt8(truncatingIfNeeded: rowFlags)

                var row = Data()
                row.appendUInt64LE(record.id)
                row.appendInt32LE(parent)
                row.appendUInt32LE(rowFlags)
                row.appendUInt64LE(record.sizeBytes)
                row.appendUInt64LE(record.modifiedTime.bitPattern)
                row.appendUInt64LE((record.createdTime ?? 0).bitPattern)
                row.appendUInt64LE(name.offset)
                row.appendUInt32LE(name.length)
                row.appendUInt64LE(normalizedName.offset)
                row.appendUInt32LE(normalizedName.length)
                row.appendUInt64LE(baseDirectory.0)
                row.appendUInt32LE(baseDirectory.1)
                row.appendUInt64LE(normalizedDirectory.0)
                row.appendUInt32LE(normalizedDirectory.1)
                row.appendUInt32LE(extensionIDs[record.fileExtension] ?? 0)
                row.appendUInt32LE(volumeIDs[record.volumeName] ?? 0)
                row.appendUInt64LE(0)

                precondition(row.count == Self.rowSize)
                try recordsHandle.write(contentsOf: row)
                lookupEntries.append((FileRecord.stableID(for: record.path), Int32(index)))
                parentColumn.appendInt32LE(parent)
                flagColumn.append(packedFlags)
                rootIDColumn.appendUInt16LE(rootAttribution.rootIDs[index])
                parents.append(parent)
                flagBytes.append(packedFlags)
                if parent >= 0 {
                    depths[index] = UInt16(min(Int(depths[Int(parent)]) + 1, Int(UInt16.max)))
                }
            }
        }

        try parentColumn.write(to: parentURL, options: .atomic)
        try flagColumn.write(to: flagsURL, options: .atomic)
        try rootIDColumn.write(to: rootIDURL, options: .atomic)
        try makeVisibleBitset(parents: parents, flags: flagBytes).write(to: visibleURL, options: .atomic)
        try makeSubtreeEndColumn(parents: parents).write(to: subtreeEndURL, options: .atomic)
        var depthColumn = Data()
        depthColumn.reserveCapacity(depths.count * 2)
        for depth in depths {
            depthColumn.appendUInt16LE(depth)
        }
        try depthColumn.write(to: depthURL, options: .atomic)

        lookupEntries.sort {
            if $0.hash != $1.hash { return $0.hash < $1.hash }
            return $0.rowID < $1.rowID
        }

        var lookupHeader = Data()
        lookupHeader.appendUInt64LE(Self.pathLookupMagic)
        lookupHeader.appendUInt32LE(1)
        lookupHeader.appendUInt32LE(UInt32(Self.pathLookupEntrySize))
        lookupHeader.appendUInt64LE(UInt64(lookupEntries.count))
        try lookupHandle.write(contentsOf: lookupHeader)

        for entry in lookupEntries {
            var data = Data()
            data.appendUInt64LE(entry.hash)
            data.appendInt32LE(entry.rowID)
            data.appendUInt32LE(0)
            try lookupHandle.write(contentsOf: data)
        }

        try Data().write(to: packageURL.appendingPathComponent(SnapshotLayout.FileName.modifiedOrder, isDirectory: false))
        try Data().write(to: packageURL.appendingPathComponent(SnapshotLayout.FileName.namePostings, isDirectory: false))
        try Data().write(to: packageURL.appendingPathComponent(SnapshotLayout.FileName.componentPostings, isDirectory: false))
        try Data().write(to: packageURL.appendingPathComponent(SnapshotLayout.FileName.pathPostings, isDirectory: false))
        try Data().write(to: packageURL.appendingPathComponent(SnapshotLayout.FileName.extensionPostings, isDirectory: false))
    }

    private static func bitsetByteCount(for bitCount: Int) -> Int {
        (bitCount + 7) / 8
    }

    private static func bitsetValue(in data: Data, at index: Int) -> Bool {
        let byte = data[index / 8]
        return byte & (UInt8(1) << UInt8(index % 8)) != 0
    }

    private static func setBit(in data: inout Data, at index: Int) {
        let byteIndex = index / 8
        let mask = UInt8(1) << UInt8(index % 8)
        data[byteIndex] |= mask
    }

    private static func countVisibleRows(in data: Data, rowCount: Int) -> Int {
        guard rowCount > 0 else { return 0 }

        var count = 0
        for rowID in 0..<rowCount where bitsetValue(in: data, at: rowID) {
            count += 1
        }
        return count
    }

    private static func countResultRows(flagsData: Data, rowCount: Int) -> Int {
        guard rowCount > 0 else { return 0 }

        var count = 0
        for rowID in 0..<rowCount where flagsData[rowID] & virtualFlag == 0 {
            count += 1
        }
        return count
    }

    private static func rootIDsAreValid(_ data: Data, rowCount: Int, rootCount: Int) -> Bool {
        guard data.count == rowCount * 2 else { return false }
        for rowID in 0..<rowCount {
            let rootID = data.readUInt16LE(at: rowID * 2)
            guard rootID == RootAttributionTable.unassignedRootID || Int(rootID) < rootCount else {
                return false
            }
        }
        return true
    }

    private static func makeVisibleBitset(parents: [Int32], flags: [UInt8]) -> Data {
        precondition(parents.count == flags.count)

        var memo = Array(repeating: Int8(-1), count: parents.count)
        func isHiddenInPath(_ rowID: Int) -> Bool {
            switch memo[rowID] {
            case 0:
                return false
            case 1:
                return true
            default:
                break
            }

            let parent = parents[rowID]
            let hidden = flags[rowID] & 2 != 0
                || (parent >= 0 && Int(parent) != rowID && isHiddenInPath(Int(parent)))
            memo[rowID] = hidden ? 1 : 0
            return hidden
        }

        var data = Data(repeating: 0, count: bitsetByteCount(for: parents.count))
        for rowID in 0..<parents.count where flags[rowID] & virtualFlag == 0 && !isHiddenInPath(rowID) {
            setBit(in: &data, at: rowID)
        }
        return data
    }

    private static func makeSubtreeEndColumn(parents: [Int32]) -> Data {
        var ends = (0..<parents.count).map { Int32($0 + 1) }
        guard !parents.isEmpty else { return Data() }

        for rowID in stride(from: parents.count - 1, through: 0, by: -1) {
            let parent = parents[rowID]
            guard parent >= 0 else { continue }
            let parentRow = Int(parent)
            guard parentRow >= 0, parentRow < rowID else { continue }
            ends[parentRow] = max(ends[parentRow], ends[rowID])
        }

        var data = Data()
        data.reserveCapacity(ends.count * 4)
        for end in ends {
            data.appendInt32LE(end)
        }
        return data
    }

    private static func sortedInterns(_ ids: [String: UInt32]) -> [String] {
        ids.sorted { $0.value < $1.value }.map(\.key)
    }

    private static func writeInterns(extensions: [String], volumes: [String], to url: URL) throws {
        var data = Data()
        func appendTable(_ values: [String]) {
            data.appendUInt32LE(UInt32(values.count))
            for value in values {
                let bytes = Data(value.utf8)
                data.appendUInt32LE(UInt32(bytes.count))
                data.append(bytes)
            }
        }
        appendTable(extensions)
        appendTable(volumes)
        try data.write(to: url, options: .atomic)
    }
}

final class MappedIntPostingIndex: @unchecked Sendable {
    private static let magic: UInt64 = 0x3150495441545441 // ATTIP1 little-endian bytes.
    private static let headerSize = 32
    private static let entrySize = 16

    private let data: Data
    private let temporaryURL: URL?
    let keyCount: Int
    let postingCount: Int

    private init(data: Data, temporaryURL: URL?) throws {
        guard
            data.count >= Self.headerSize,
            data.readUInt64LE(at: 0) == Self.magic
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let keyCount = Int(data.readUInt64LE(at: 8))
        let postingCount = Int(data.readUInt64LE(at: 16))
        let expectedCount = Self.headerSize + keyCount * Self.entrySize + postingCount * 4
        guard data.count == expectedCount else {
            throw CocoaError(.fileReadCorruptFile)
        }

        self.data = data
        self.temporaryURL = temporaryURL
        self.keyCount = keyCount
        self.postingCount = postingCount
    }

    convenience init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        try self.init(data: data, temporaryURL: nil)
    }

    deinit {
        if let temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
    }

    static func build(from index: [Int: [Int32]], temporaryName: String) throws -> MappedIntPostingIndex? {
        guard !index.isEmpty else { return nil }

        let temporaryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(temporaryName)-\(UUID().uuidString).bin", isDirectory: false)
        var data = Data()
        let sortedEntries = index.sorted { $0.key < $1.key }
        let postingCount = sortedEntries.reduce(0) { $0 + $1.value.count }

        data.reserveCapacity(Self.headerSize + sortedEntries.count * Self.entrySize + postingCount * 4)
        data.appendUInt64LE(Self.magic)
        data.appendUInt64LE(UInt64(sortedEntries.count))
        data.appendUInt64LE(UInt64(postingCount))
        data.appendUInt64LE(0)

        var postingOffset = 0
        for (key, values) in sortedEntries {
            data.appendInt32LE(Int32(key))
            data.appendUInt32LE(UInt32(postingOffset))
            data.appendUInt32LE(UInt32(values.count))
            data.appendUInt32LE(0)
            postingOffset += values.count
        }

        for (_, values) in sortedEntries {
            for value in values {
                data.appendInt32LE(value)
            }
        }

        try data.write(to: temporaryURL, options: .atomic)
        let mapped = try Data(contentsOf: temporaryURL, options: [.mappedIfSafe])
        return try MappedIntPostingIndex(data: mapped, temporaryURL: temporaryURL)
    }

    static func load(from url: URL, fileManager: FileManager = .default) throws -> MappedIntPostingIndex? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 else {
            return nil
        }

        return try MappedIntPostingIndex(contentsOf: url)
    }

    func write(to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    func values(for key: Int) -> [Int32]? {
        var low = 0
        var high = keyCount

        while low < high {
            let mid = (low + high) / 2
            let midKey = entryKey(at: mid)
            if midKey < key {
                low = mid + 1
            } else {
                high = mid
            }
        }

        guard low < keyCount, entryKey(at: low) == key else {
            return nil
        }

        let offset = entryOffset(at: low)
        let count = entryCount(at: low)
        let postingsStart = Self.headerSize + keyCount * Self.entrySize + offset * 4

        var result: [Int32] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            result.append(data.readInt32LE(at: postingsStart + index * 4))
        }
        return result
    }

    private func entryKey(at index: Int) -> Int {
        Int(data.readInt32LE(at: Self.headerSize + index * Self.entrySize))
    }

    private func entryOffset(at index: Int) -> Int {
        Int(data.readUInt32LE(at: Self.headerSize + index * Self.entrySize + 4))
    }

    private func entryCount(at index: Int) -> Int {
        Int(data.readUInt32LE(at: Self.headerSize + index * Self.entrySize + 8))
    }
}

enum CompactSearchStructureFiles {
    private static let modifiedOrderMagic: UInt64 = 0x31444f4d54415441 // ATTMOD1 little-endian bytes.
    private static let modifiedOrderVersion: UInt32 = 1
    private static let modifiedOrderHeaderSize = 24

    static func loadModifiedOrder(
        from url: URL,
        expectedCount: Int,
        rowIDUpperBound: Int? = nil,
        fileManager: FileManager = .default
    ) -> [Int]? {
        let rowIDUpperBound = rowIDUpperBound ?? expectedCount
        guard expectedCount >= 0, rowIDUpperBound >= expectedCount, fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        guard
            let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 0,
            let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
            data.count == modifiedOrderHeaderSize + expectedCount * 4,
            data.readUInt64LE(at: 0) == modifiedOrderMagic,
            data.readUInt32LE(at: 8) == modifiedOrderVersion,
            Int(data.readUInt64LE(at: 16)) == expectedCount
        else {
            return nil
        }

        var seen = Set<Int>()
        seen.reserveCapacity(expectedCount)
        var order: [Int] = []
        order.reserveCapacity(expectedCount)

        for index in 0..<expectedCount {
            let rowID = Int(data.readInt32LE(at: modifiedOrderHeaderSize + index * 4))
            guard rowID >= 0, rowID < rowIDUpperBound, seen.insert(rowID).inserted else {
                return nil
            }
            order.append(rowID)
        }

        return order
    }

    static func writeModifiedOrder(_ order: [Int], to url: URL) throws {
        var data = Data()
        data.reserveCapacity(modifiedOrderHeaderSize + order.count * 4)
        data.appendUInt64LE(modifiedOrderMagic)
        data.appendUInt32LE(modifiedOrderVersion)
        data.appendUInt32LE(4)
        data.appendUInt64LE(UInt64(order.count))

        for rowID in order {
            data.appendInt32LE(Int32(rowID))
        }

        try data.write(to: url, options: .atomic)
    }
}

struct CompactSnapshotManifest: Codable, Sendable {
    let schemaVersion: Int
    let savedAt: Date
    let roots: [String]
    let exclusionPatterns: [String]
    let recordCount: Int
    let resultCount: Int?
    let rootEventIDs: [String: UInt64]?

    init(
        schemaVersion: Int,
        savedAt: Date,
        roots: [String],
        exclusionPatterns: [String],
        recordCount: Int,
        resultCount: Int? = nil,
        rootEventIDs: [String: UInt64]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.roots = roots
        self.exclusionPatterns = exclusionPatterns
        self.recordCount = recordCount
        self.resultCount = resultCount
        self.rootEventIDs = rootEventIDs
    }
}

private final class PathMaterializationCache: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var paths: [Int: String] = [:]
    private var directories: [Int: String] = [:]
    private var normalizedPaths: [Int: String] = [:]

    init(limit: Int) {
        self.limit = limit
    }

    func path(for row: Int) -> String? {
        lock.withLock { paths[row] }
    }

    func setPath(_ value: String, for row: Int) {
        lock.withLock {
            evictIfNeeded(&paths)
            paths[row] = value
        }
    }

    func directoryPath(for row: Int) -> String? {
        lock.withLock { directories[row] }
    }

    func setDirectoryPath(_ value: String, for row: Int) {
        lock.withLock {
            evictIfNeeded(&directories)
            directories[row] = value
        }
    }

    func normalizedPath(for row: Int) -> String? {
        lock.withLock { normalizedPaths[row] }
    }

    func setNormalizedPath(_ value: String, for row: Int) {
        lock.withLock {
            evictIfNeeded(&normalizedPaths)
            normalizedPaths[row] = value
        }
    }

    private func evictIfNeeded(_ values: inout [Int: String]) {
        guard values.count >= limit, let key = values.keys.first else {
            return
        }
        values.removeValue(forKey: key)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(contentsOf: [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff)
        ])
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff)
        ])
    }

    mutating func appendInt32LE(_ value: Int32) {
        appendUInt32LE(UInt32(bitPattern: value))
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        append(contentsOf: [
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

    func readUInt32LE(at offset: Int) -> UInt32 {
        precondition(offset >= 0 && offset + 4 <= count)
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func readInt32LE(at offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32LE(at: offset))
    }

    func readUInt16LE(at offset: Int) -> UInt16 {
        precondition(offset >= 0 && offset + 2 <= count)
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readUInt64LE(at offset: Int) -> UInt64 {
        precondition(offset >= 0 && offset + 8 <= count)
        var result: UInt64 = 0
        for index in 0..<8 {
            result |= UInt64(self[offset + index]) << UInt64(index * 8)
        }
        return result
    }

    func containsBytes(_ needle: [UInt8], in range: Range<Int>) -> Bool {
        guard !needle.isEmpty else { return true }
        guard range.lowerBound >= 0, range.upperBound <= count, needle.count <= range.count else {
            return false
        }

        return withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return false
            }
            return needle.withUnsafeBufferPointer { needleBuffer in
                guard let needleAddress = needleBuffer.baseAddress else {
                    return false
                }
                return Self.containsBytes(
                    haystack: baseAddress.advanced(by: range.lowerBound),
                    haystackCount: range.count,
                    needle: needleAddress,
                    needleCount: needle.count
                )
            }
        }
    }

    private static func containsBytes(
        haystack: UnsafePointer<UInt8>,
        haystackCount: Int,
        needle: UnsafePointer<UInt8>,
        needleCount: Int
    ) -> Bool {
        guard needleCount <= haystackCount else { return false }

        let first = needle[0]
        let firstVector = SIMD16<UInt8>(repeating: first)
        let lastStart = haystackCount - needleCount
        var offset = 0

        while offset + 16 <= haystackCount {
            let chunk = SIMD16<UInt8>(UnsafeBufferPointer(start: haystack.advanced(by: offset), count: 16))
            let matches = chunk .== firstVector
            for lane in 0..<16 {
                let candidate = offset + lane
                if candidate > lastStart {
                    break
                }
                if matches[lane], bytesMatch(haystack.advanced(by: candidate), needle, count: needleCount) {
                    return true
                }
            }
            offset += 16
        }

        guard offset <= lastStart else { return false }
        for candidate in offset...lastStart where haystack[candidate] == first {
            if bytesMatch(haystack.advanced(by: candidate), needle, count: needleCount) {
                return true
            }
        }
        return false
    }

    private static func bytesMatch(_ lhs: UnsafePointer<UInt8>, _ rhs: UnsafePointer<UInt8>, count: Int) -> Bool {
        for index in 0..<count where lhs[index] != rhs[index] {
            return false
        }
        return true
    }
}
