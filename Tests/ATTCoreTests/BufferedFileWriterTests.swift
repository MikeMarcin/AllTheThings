@testable import ATTCore
import Foundation
import Testing

@Suite("Buffered file writer")
struct BufferedFileWriterTests {
    @Test("coalesces small payloads and preserves their bytes across flush boundaries")
    func coalescesSmallPayloadsWithoutChangingBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AllTheThings-BufferedFileWriterTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("output.bin", isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(FileManager.default.createFile(atPath: fileURL.path, contents: nil))

        let handle = try FileHandle(forWritingTo: fileURL)
        let writer = BufferedFileWriter(handle: handle, bufferSize: 8)
        let payloads = [
            Data([0, 1, 2]),
            Data([3, 4]),
            Data([5, 6, 7, 8]),
            Data([9, 10, 11, 12, 13, 14, 15, 16, 17, 18])
        ]

        for payload in payloads {
            try writer.write(contentsOf: payload)
        }
        try writer.flush()
        try handle.close()

        #expect(try Data(contentsOf: fileURL) == payloads.reduce(into: Data()) { $0.append($1) })
        #expect(writer.physicalWriteCount == 3)
    }
}
