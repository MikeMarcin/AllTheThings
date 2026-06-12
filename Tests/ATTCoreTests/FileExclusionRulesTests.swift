@testable import ATTCore
import Dispatch
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
            "/tmp/project/Engine/DerivedDataCache/Boot.ddc",
            "/tmp/project/Engine/Intermediate/Build/Target.make",
            "/tmp/project/Engine/Saved/Logs/Editor.log",
            "/tmp/project/build/.cmake/api/v1/reply/index-123.json",
            "/tmp/project/build/_deps/llvm_project-src/clang/test/Sema/File.cpp",
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
        #expect(!rules.excludes(
            url: URL(fileURLWithPath: "/tmp/project/Engine/Content/Internationalization/icudt64l/hu.res"),
            roots: [root],
            isDirectory: false
        ))
        #expect(!rules.excludes(
            url: URL(fileURLWithPath: "/tmp/project/Engine/Source/ThirdParty/Licenses/zlib.txt"),
            roots: [root],
            isDirectory: false
        ))
        #expect(!rules.excludes(
            url: URL(fileURLWithPath: "/tmp/project/Engine/Source/Runtime/Engine/Private/Generated.cpp"),
            roots: [root],
            isDirectory: false
        ))
        #expect(!rules.excludes(
            url: URL(fileURLWithPath: "/tmp/project/thirdparty/nlohmann-json/test/data/case.json"),
            roots: [root],
            isDirectory: false
        ))
        #expect(!rules.excludes(
            url: URL(fileURLWithPath: "/tmp/project/third_party/openssl/include/openssl/ssl.h"),
            roots: [root],
            isDirectory: false
        ))
        #expect(!rules.excludes(
            url: URL(fileURLWithPath: "/tmp/project/vendor/library/src/file.c"),
            roots: [root],
            isDirectory: false
        ))
    }

    @Test("ordered decisions support traversal-only re-includes")
    func orderedDecisionsSupportTraversalOnlyReIncludes() {
        let root = "/tmp/project"
        let rules = FileExclusionRules(patterns: [
            "*",
            "!*/",
            "!*.swift",
            "Generated/",
            "!Generated/Keep.swift",
            "Logs/"
        ])

        #expect(rules.decision(
            url: URL(fileURLWithPath: "/tmp/project/Sources"),
            roots: [root],
            isDirectory: true
        ) == .skipButDescend)
        #expect(rules.decision(
            url: URL(fileURLWithPath: "/tmp/project/Sources/App.swift"),
            roots: [root],
            isDirectory: false
        ) == .index)
        #expect(rules.decision(
            url: URL(fileURLWithPath: "/tmp/project/Sources/README.md"),
            roots: [root],
            isDirectory: false
        ) == .prune)
        #expect(rules.decision(
            url: URL(fileURLWithPath: "/tmp/project/Generated"),
            roots: [root],
            isDirectory: true
        ) == .skipButDescend)
        #expect(rules.decision(
            url: URL(fileURLWithPath: "/tmp/project/Generated/Keep.swift"),
            roots: [root],
            isDirectory: false
        ) == .index)
        #expect(rules.decision(
            url: URL(fileURLWithPath: "/tmp/project/Generated/Drop.swift"),
            roots: [root],
            isDirectory: false
        ) == .prune)
        #expect(rules.decision(
            url: URL(fileURLWithPath: "/tmp/project/Logs"),
            roots: [root],
            isDirectory: true
        ) == .prune)
    }

    @Test("rules support root anchors and character classes")
    func rulesSupportRootAnchorsAndCharacterClasses() {
        let root = "/tmp/project"
        let rules = FileExclusionRules(patterns: [
            "/[Dd]esktop.ini"
        ])

        #expect(rules.decision(
            url: URL(fileURLWithPath: "/tmp/project/Desktop.ini"),
            roots: [root],
            isDirectory: false
        ) == .prune)
        #expect(rules.decision(
            url: URL(fileURLWithPath: "/tmp/project/desktop.ini"),
            roots: [root],
            isDirectory: false
        ) == .prune)
        #expect(rules.decision(
            url: URL(fileURLWithPath: "/tmp/project/Nested/Desktop.ini"),
            roots: [root],
            isDirectory: false
        ) == .index)
    }

    @Test("default git rules keep useful files and drop volatile internals")
    func defaultGitRulesKeepUsefulFilesAndDropVolatileInternals() {
        let root = "/tmp/project"
        let rules = FileExclusionRules()

        let includedPaths = [
            "/tmp/project/.git/config",
            "/tmp/project/.git/HEAD",
            "/tmp/project/.git/description",
            "/tmp/project/.git/hooks/pre-commit",
            "/tmp/project/.git/info/exclude"
        ]
        for path in includedPaths {
            #expect(rules.decision(
                url: URL(fileURLWithPath: path),
                roots: [root],
                isDirectory: false
            ) == .index)
        }

        let excludedPaths = [
            "/tmp/project/.git/FETCH_HEAD",
            "/tmp/project/.git/index",
            "/tmp/project/.git/index.lock",
            "/tmp/project/.git/packed-refs",
            "/tmp/project/.git/objects/ab/cdef",
            "/tmp/project/.git/refs/heads/main",
            "/tmp/project/.git/logs/HEAD",
            "/tmp/project/.git/fsmonitor--daemon/ipc"
        ]
        for path in excludedPaths {
            #expect(rules.decision(
                url: URL(fileURLWithPath: path),
                roots: [root],
                isDirectory: false
            ) == .prune)
        }
    }

    @Test("rule decisions are safe under concurrent scanner workers")
    func ruleDecisionsAreSafeUnderConcurrentScannerWorkers() {
        let root = "/tmp/project"
        let rules = FileExclusionRules(patterns: FileExclusionRules.defaultPatterns + [
            "*",
            "!*/",
            "!*.swift",
            "!Package.swift",
            "Generated/",
            "!Generated/Keep.swift",
            "Vendor/**/Build/"
        ])
        let samples: [(path: String, isDirectory: Bool, expected: FileExclusionRules.Decision)] = [
            ("/tmp/project/Sources/App.swift", false, .index),
            ("/tmp/project/Sources/Feature/Subfeature/ViewModel.swift", false, .index),
            ("/tmp/project/Sources/Feature/Subfeature/README.md", false, .prune),
            ("/tmp/project/Package.swift", false, .index),
            ("/tmp/project/Generated", true, .skipButDescend),
            ("/tmp/project/Generated/Keep.swift", false, .index),
            ("/tmp/project/Generated/Drop.swift", false, .prune),
            ("/tmp/project/Vendor/Library/Build", true, .prune),
            ("/tmp/project/node_modules/react/index.js", false, .prune)
        ]
        let recorder = ConcurrentMismatchRecorder()

        DispatchQueue.concurrentPerform(iterations: 2_000) { iteration in
            let sample = samples[iteration % samples.count]
            let decision = rules.decision(
                url: URL(fileURLWithPath: sample.path),
                roots: [root],
                isDirectory: sample.isDirectory
            )
            if decision != sample.expected {
                recorder.append("\(sample.path): expected \(sample.expected), got \(decision)")
            }
        }

        #expect(recorder.messages.isEmpty)
    }

    @Test("compiled query matches full rules for fixture matrix")
    func compiledQueryMatchesFullRulesForFixtureMatrix() {
        assertCompiledQueryParity(
            patterns: FileExclusionRules.defaultPatterns,
            roots: ["/tmp/project"],
            samples: [
                ("/tmp/project", true),
                ("/tmp/project/Sources/App.swift", false),
                ("/tmp/project/node_modules", true),
                ("/tmp/project/node_modules/react/index.js", false),
                ("/tmp/project/.git", true),
                ("/tmp/project/.git/config", false),
                ("/tmp/project/.git/hooks", true),
                ("/tmp/project/.git/hooks/pre-commit", false),
                ("/tmp/project/.git/objects", true),
                ("/tmp/project/.git/objects/ab/cdef", false),
                ("/tmp/project/Library", true),
                ("/tmp/project/Library/Caches", true),
                ("/tmp/project/Library/Caches/com.example/cache.db", false),
                ("/tmp/project/Example.app/Contents/_CodeSignature", true),
                ("/tmp/project/Example.app/Contents/_CodeSignature/CodeResources", false),
                ("/tmp/project/.build/arm64-apple-macosx/debug/index/store", true),
                ("/tmp/project/.build/arm64-apple-macosx/debug/index/store/v5/records/unit", false),
                ("/tmp/project/Engine/Binaries/ThirdParty/DotNet/8.0/sdk/tool.dll", false),
                ("/tmp/project/Engine/Source/Runtime/Engine/Private/Generated.cpp", false)
            ]
        )

        assertCompiledQueryParity(
            patterns: [
                "*",
                "!*/",
                "!*.swift",
                "Generated/",
                "!Generated/Keep.swift",
                "Logs/"
            ],
            roots: ["/tmp/project"],
            samples: [
                ("/tmp/project/Sources", true),
                ("/tmp/project/Sources/App.swift", false),
                ("/tmp/project/Sources/README.md", false),
                ("/tmp/project/Generated", true),
                ("/tmp/project/Generated/Keep.swift", false),
                ("/tmp/project/Generated/Drop.swift", false),
                ("/tmp/project/Logs", true),
                ("/tmp/project/Logs/Debug.log", false)
            ]
        )

        assertCompiledQueryParity(
            patterns: FileExclusionRules.defaultPatterns,
            roots: ["/tmp/project", "/tmp/project/Nested"],
            samples: [
                ("/tmp/project/Nested", true),
                ("/tmp/project/Nested/Sources/App.swift", false),
                ("/tmp/project/Nested/.cache", true),
                ("/tmp/project/Nested/.cache/build.db", false),
                ("/tmp/project/Nested/.git", true),
                ("/tmp/project/Nested/.git/config", false),
                ("/tmp/project/Nested/.git/objects/ab/cdef", false)
            ]
        )
    }

    private func assertCompiledQueryParity(
        patterns: [String],
        roots: [String],
        samples: [(path: String, isDirectory: Bool)]
    ) {
        let rules = FileExclusionRules(patterns: patterns)
        let query = rules.makeQuery(roots: roots)

        for sample in samples {
            var instrumentation = FileExclusionQuery.Instrumentation()
            let queryDecision = query.decision(
                path: sample.path,
                isDirectory: sample.isDirectory,
                instrumentation: &instrumentation
            )
            let fullDecision = rules.decision(
                url: URL(fileURLWithPath: sample.path, isDirectory: sample.isDirectory),
                roots: roots,
                isDirectory: sample.isDirectory
            )
            #expect(queryDecision == fullDecision)
        }
    }
}

private final class ConcurrentMismatchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMessages: [String] = []

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedMessages
    }

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        storedMessages.append(message)
    }
}
