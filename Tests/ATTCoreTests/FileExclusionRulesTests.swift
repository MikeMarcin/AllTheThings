import ATTCore
import Foundation
import Testing

@Suite("File exclusion rules")
struct FileExclusionRulesTests {
    @Test("default rules skip common index noise")
    func defaultRulesSkipCommonIndexNoise() {
        let root = "/tmp/project"
        let rules = FileExclusionRules()

        let excludedPaths = [
            "/tmp/project/.git/objects/ab/cdef",
            "/tmp/project/.git/modules/dependency/objects/pack/pack-123.idx",
            "/tmp/project/.git/lfs/objects/ab/cd/blob",
            "/tmp/project/node_modules/react/index.js",
            "/tmp/project/DerivedData/Build/Products/App.app",
            "/tmp/project/.next/cache/webpack/client.js",
            "/tmp/project/.gradle/caches/modules-2/files-2.1/package.bin",
            "/tmp/project/Engine/Binaries/ThirdParty/DotNet/8.0.412/win-arm64/sdk/tool.dll",
            "/tmp/project/__pycache__/module.pyc",
            "/tmp/project/Library/Caches/com.example/cache.db"
        ]

        for path in excludedPaths {
            #expect(rules.excludes(
                url: URL(fileURLWithPath: path),
                roots: [root],
                isDirectory: false
            ))
        }

        #expect(!rules.excludes(
            url: URL(fileURLWithPath: "/tmp/project/Sources/App.swift"),
            roots: [root],
            isDirectory: false
        ))
        #expect(!rules.excludes(
            url: URL(fileURLWithPath: "/tmp/project/build/App.o"),
            roots: [root],
            isDirectory: false
        ))
        #expect(!rules.excludes(
            url: URL(fileURLWithPath: "/tmp/project/out/generated.json"),
            roots: [root],
            isDirectory: false
        ))
        #expect(!rules.excludes(
            url: URL(fileURLWithPath: "/tmp/project/target/debug/app"),
            roots: [root],
            isDirectory: false
        ))
    }
}
