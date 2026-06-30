import Foundation

enum SnapshotLayout {
    static let schemaVersion = 7
    static let packageName = "filename-index-v\(schemaVersion).attindex"
    static let temporaryPackagePrefix = "filename-index-v\(schemaVersion)-"
    static let temporaryPackageSuffix = ".attindex.tmp"
    static let checkpointPackageName = "filename-index-v\(schemaVersion)-checkpoint.attindex"
    static let temporaryCheckpointPackagePrefix = "filename-index-v\(schemaVersion)-checkpoint-"

    static let obsoletePackageNames = [
        "filename-index-v6.attindex",
        "filename-index-v6-checkpoint.attindex",
        "filename-index-v5.attindex",
        "filename-index-v4.attindex"
    ]

    static let obsoleteFileNames = [
        "filename-index-v2.jsonl",
        "filename-index.json",
        "filename-index.json.tmp"
    ]

    enum FileName {
        static let manifest = "manifest.json"
        static let records = "records.bin"
        static let strings = "strings.bin"
        static let interns = "interns.bin"
        static let pathLookup = "pathLookup.bin"
        static let parent = "parent.i32"
        static let flags = "flags.u8"
        static let visible = "visible.bitset"
        static let subtreeEnd = "subtreeEnd.i32"
        static let depth = "depth.u16"
        static let rootID = "rootID.u16"
        static let roots = "roots.json"
        static let modifiedOrder = "modifiedOrder.bin"
        static let visibleModifiedOrder = "visibleModifiedOrder.i32"
        static let namePostings = "namePostings.bin"
        static let componentPostings = "componentPostings.bin"
        static let pathPostings = "pathPostings.bin"
        static let extensionPostings = "extensionPostings.bin"
        static let metadataOverlay = "metadataOverlay.bin"
        static let scanState = "scan-state.json"
    }

    static func packageURL(in supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent(packageName, isDirectory: true)
    }

    static func temporaryPackageURL(in supportDirectory: URL, id: UUID = UUID()) -> URL {
        supportDirectory.appendingPathComponent(
            "\(temporaryPackagePrefix)\(id.uuidString)\(temporaryPackageSuffix)",
            isDirectory: true
        )
    }

    static func checkpointPackageURL(in supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent(checkpointPackageName, isDirectory: true)
    }

    static func temporaryCheckpointPackageURL(in supportDirectory: URL, id: UUID = UUID()) -> URL {
        supportDirectory.appendingPathComponent(
            "\(temporaryCheckpointPackagePrefix)\(id.uuidString)\(temporaryPackageSuffix)",
            isDirectory: true
        )
    }

    static func isCurrentTemporaryPackageName(_ name: String) -> Bool {
        (name.hasPrefix(temporaryPackagePrefix) || name.hasPrefix(temporaryCheckpointPackagePrefix))
            && name.hasSuffix(temporaryPackageSuffix)
    }

    static func isCheckpointPackageName(_ name: String) -> Bool {
        name == checkpointPackageName
    }

    static func isObsoleteTemporaryName(_ name: String) -> Bool {
        (name.hasPrefix("filename-index-v6-") && name.hasSuffix(".attindex.tmp"))
            || (name.hasPrefix("filename-index-v5-") && name.hasSuffix(".attindex.tmp"))
            || (name.hasPrefix("filename-index-v4-") && name.hasSuffix(".attindex.tmp"))
            || (name.hasPrefix("filename-index-v2-") && name.hasSuffix(".jsonl.tmp"))
    }
}
