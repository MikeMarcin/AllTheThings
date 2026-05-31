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
            "/tmp/project/Example.app/Contents/_CodeSignature/CodeResources",
            "/tmp/project/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/usr/include/stdio.h",
            "/tmp/project/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift",
            "/tmp/project/Engine/Binaries/ThirdParty/DotNet/8.0.412/win-arm64/sdk/tool.dll",
            "/tmp/project/Engine/Binaries/ThirdParty/Python3/Win64/Lib/urllib/request.py",
            "/tmp/project/Engine/Content/Internationalization/icudt64l/hu.res",
            "/tmp/project/Engine/Source/ThirdParty/Licenses/zlib.txt",
            "/tmp/project/Engine/Source/Runtime/Engine/Private/Generated.cpp",
            "/tmp/project/build/.cmake/api/v1/reply/index-123.json",
            "/tmp/project/build/_deps/llvm_project-src/clang/test/Sema/File.cpp",
            "/tmp/project/thirdparty/nlohmann-json/test/data/case.json",
            "/tmp/project/third_party/openssl/include/openssl/ssl.h",
            "/tmp/project/vendor/library/src/file.c",
            "/tmp/project/.venv/lib/python3.14/site-packages/babel/locale-data/en.dat",
            "/tmp/project/.build/arm64-apple-macosx/debug/index/store/v5/records/2W/unit",
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
