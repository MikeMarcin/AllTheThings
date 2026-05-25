import Foundation

public struct FileRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: UInt64
    public let path: String
    public let name: String
    public let directoryPath: String
    public let fileExtension: String
    public let sizeBytes: UInt64
    public let modifiedTime: TimeInterval
    public let createdTime: TimeInterval?
    public let isDirectory: Bool
    public let isHidden: Bool
    public let volumeName: String
    public let normalizedName: String
    public let normalizedPath: String

    public var modifiedDate: Date {
        Date(timeIntervalSinceReferenceDate: modifiedTime)
    }

    public var createdDate: Date? {
        createdTime.map { Date(timeIntervalSinceReferenceDate: $0) }
    }

    public var url: URL {
        URL(fileURLWithPath: path)
    }

    public init(
        id: UInt64,
        path: String,
        name: String,
        directoryPath: String,
        fileExtension: String,
        sizeBytes: UInt64,
        modifiedTime: TimeInterval,
        createdTime: TimeInterval?,
        isDirectory: Bool,
        isHidden: Bool,
        volumeName: String,
        normalizedName: String,
        normalizedPath: String
    ) {
        self.id = id
        self.path = path
        self.name = name
        self.directoryPath = directoryPath
        self.fileExtension = fileExtension
        self.sizeBytes = sizeBytes
        self.modifiedTime = modifiedTime
        self.createdTime = createdTime
        self.isDirectory = isDirectory
        self.isHidden = isHidden
        self.volumeName = volumeName
        self.normalizedName = normalizedName
        self.normalizedPath = normalizedPath
    }

    public static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isHiddenKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .creationDateKey,
        .volumeNameKey
    ]

    public init?(
        url: URL,
        resourceValues values: URLResourceValues? = nil
    ) {
        let standardizedURL = url.standardizedFileURL
        let path = standardizedURL.path
        let name = standardizedURL.lastPathComponent.isEmpty ? path : standardizedURL.lastPathComponent
        let directoryPath = standardizedURL.deletingLastPathComponent().path

        let loadedValues: URLResourceValues
        do {
            loadedValues = try values ?? standardizedURL.resourceValues(forKeys: Self.resourceKeys)
        } catch {
            return nil
        }

        let isDirectory = loadedValues.isDirectory ?? false
        let isHidden = (loadedValues.isHidden ?? false) || name.hasPrefix(".")
        let size = UInt64(max(loadedValues.fileSize ?? 0, 0))
        let modified = loadedValues.contentModificationDate ?? .distantPast
        let created = loadedValues.creationDate
        let ext = standardizedURL.pathExtension.lowercased()
        let normalizedName = FuzzyMatcher.normalize(name)
        let normalizedPath = FuzzyMatcher.normalize(path)

        self.id = Self.stableID(for: path)
        self.path = path
        self.name = name
        self.directoryPath = directoryPath
        self.fileExtension = ext
        self.sizeBytes = isDirectory ? 0 : size
        self.modifiedTime = modified.timeIntervalSinceReferenceDate
        self.createdTime = created?.timeIntervalSinceReferenceDate
        self.isDirectory = isDirectory
        self.isHidden = isHidden
        self.volumeName = loadedValues.volumeName ?? ""
        self.normalizedName = normalizedName
        self.normalizedPath = normalizedPath
    }

    public static func stableID(for path: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash == 0 ? 1 : hash
    }
}
