@testable import ATTCore
import Testing

@Suite("File record")
struct FileRecordTests {
    @Test("hidden paths are detected without treating dot navigation as hidden")
    func hiddenPathDetection() {
        #expect(!FileRecord.pathIsHidden("/"))
        #expect(!FileRecord.pathIsHidden("/tmp/Visible.swift"))
        #expect(!FileRecord.pathIsHidden("/tmp/./Visible.swift"))
        #expect(!FileRecord.pathIsHidden("/tmp/../Visible.swift"))
        #expect(FileRecord.pathIsHidden("/tmp/.git/config"))
        #expect(FileRecord.pathIsHidden("/tmp/Folder/.hidden"))
        #expect(FileRecord.pathIsHidden("/tmp/.../Visible.swift"))
        #expect(FileRecord.pathIsHidden(".relative/Visible.swift"))
    }
}
